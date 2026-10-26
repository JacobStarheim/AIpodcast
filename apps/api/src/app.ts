import express, { type NextFunction, type Request, type Response } from "express";
import cors from "cors";
import multer from "multer";
import type {
  PodcastSearchResponse,
  SourceListResponse,
  TranscribeEpisodeResponse,
  TranscriptionStatus
} from "@podcast/shared-types";
import { answerQuestion } from "./qa-service.js";
import { sanitizeHistory } from "./retrieval.js";
import {
  errorHandler,
  HttpError,
  RateLimiter,
  requestId,
  requireAdminKey,
  requireAppKey
} from "./security.js";
import type { AIClient, PodcastDirectory, Repository } from "./types.js";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STATUSES: TranscriptionStatus[] = ["pending", "queued", "processing", "ready", "failed"];
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function asyncRoute(handler: (req: Request, res: Response) => Promise<void>) {
  return (req: Request, res: Response, next: NextFunction) => {
    handler(req, res).catch(next);
  };
}

function optionalString(value: unknown, field: string, maxLength: number): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string") throw new HttpError(400, `${field} must be a string`);
  const trimmed = value.trim();
  if (trimmed.length > maxLength) throw new HttpError(400, `${field} must be at most ${maxLength} characters`);
  return trimmed || undefined;
}

function optionalUuid(value: unknown, field: string): string | undefined {
  const id = optionalString(value, field, 64);
  if (id !== undefined && !UUID_PATTERN.test(id)) throw new HttpError(400, `${field} must be a UUID`);
  return id;
}

function httpUrl(value: unknown, field: string): string | undefined {
  const raw = optionalString(value, field, 2_000);
  if (raw === undefined) return undefined;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new HttpError(400, `${field} must be a URL`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new HttpError(400, `${field} must use HTTP or HTTPS`);
  }
  return url.href;
}

function episodeIdParam(req: Request): string {
  const id = String(req.params.episodeId ?? "");
  if (!UUID_PATTERN.test(id)) throw new HttpError(404, "not_found");
  return id;
}

export function createApp(input: {
  repository: Repository;
  aiClient: AIClient;
  podcastDirectory?: PodcastDirectory;
  adminKey: string;
  appApiKey: string;
  minGroundingScore: number;
  podcastSearchCountry?: string;
  corsOrigins?: string[];
  trustProxy?: string | false;
  rateLimiter?: RateLimiter;
  logError?: (message: string, error: unknown) => void;
}) {
  const app = express();
  const limits = input.rateLimiter ?? new RateLimiter();
  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: 25 * 1024 * 1024 }
  });

  app.disable("x-powered-by");
  if (input.trustProxy) app.set("trust proxy", input.trustProxy);
  app.use(requestId);
  // The mobile app does not need CORS; browsers get it only for listed origins.
  if (input.corsOrigins?.length) app.use(cors({ origin: input.corsOrigins }));
  app.use(express.json({ limit: "256kb" }));

  app.get("/health", (_req, res) => {
    res.json({ ok: true });
  });

  const admin = express.Router();
  admin.use(limits.middleware("admin", 60, MINUTE), requireAdminKey(input.adminKey));

  admin.post("/sources", asyncRoute(async (req, res) => {
    const name = optionalString(req.body?.name, "name", 300);
    const rssUrl = httpUrl(req.body?.rssUrl, "rssUrl");
    if (!name || !rssUrl) {
      throw new HttpError(400, "name and rssUrl are required");
    }
    res.status(201).json(await input.repository.createSource({ name, rssUrl }));
  }));

  admin.post("/ingest/run", asyncRoute(async (req, res) => {
    const sourceId = optionalUuid(req.body?.sourceId, "sourceId");
    const maxEpisodesPerSource =
      typeof req.body?.maxEpisodesPerSource === "number" && Number.isFinite(req.body.maxEpisodesPerSource)
        ? clamp(Math.floor(req.body.maxEpisodesPerSource), 0, 100)
        : undefined;
    const job = await input.repository.enqueueIngestJob({ sourceId, maxEpisodesPerSource });
    res.status(202).json({ jobId: job.id, status: "queued" });
  }));

  app.use("/v1/admin", admin);

  const v1 = express.Router();
  // Authenticate first so rejected requests do not use up anyone's limits.
  v1.use(requireAppKey(input.appApiKey));
  const reads = limits.middleware("read", 300, MINUTE);

  v1.get("/podcasts/search", limits.middleware("podcast-search", 30, MINUTE), asyncRoute(async (req, res) => {
    const q = optionalString(req.query.q, "q", 100);
    if (!q || q.length < 2) throw new HttpError(400, "q must be at least 2 characters");
    const country = optionalString(req.query.country, "country", 2)?.toUpperCase()
      ?? input.podcastSearchCountry ?? "US";
    if (!/^[A-Z]{2}$/.test(country)) throw new HttpError(400, "country must be a two-letter code");
    if (!input.podcastDirectory) throw new HttpError(503, "podcast search is not configured");
    let items;
    try {
      items = await input.podcastDirectory.search(q, country);
    } catch (error) {
      (input.logError ?? console.error)("Podcast directory search failed", error);
      throw new HttpError(502, "podcast search is unavailable, try again later");
    }
    const response: PodcastSearchResponse = { items };
    res.json(response);
  }));

  v1.get("/sources", reads, asyncRoute(async (_req, res) => {
    const response: SourceListResponse = { items: await input.repository.listSources() };
    res.json(response);
  }));

  v1.post("/sources", limits.middleware("add-source", 10, HOUR), asyncRoute(async (req, res) => {
    const rssUrl = httpUrl(req.body?.rssUrl, "rssUrl");
    if (!rssUrl) throw new HttpError(400, "rssUrl is required");
    const { source, created } = await input.repository.addSource({
      rssUrl,
      name: optionalString(req.body?.name, "name", 300) ?? "",
      imageUrl: httpUrl(req.body?.imageUrl, "imageUrl") ?? null
    });
    res.status(created ? 201 : 200).json(source);
  }));

  v1.get("/episodes", reads, asyncRoute(async (req, res) => {
    const sourceId = optionalUuid(req.query.sourceId, "sourceId");
    const q = optionalString(req.query.q, "q", 200);
    const cursor = optionalString(req.query.cursor, "cursor", 500);
    const statusValues = ([] as unknown[]).concat(req.query.status ?? [])
      .flatMap((value) => (typeof value === "string" ? value.split(",") : []))
      .map((value) => value.trim())
      .filter(Boolean);
    const invalidStatus = statusValues.find((value) => !STATUSES.includes(value as TranscriptionStatus));
    if (invalidStatus) throw new HttpError(400, `Unknown status: ${invalidStatus.slice(0, 20)}`);
    const requestedLimit = typeof req.query.limit === "string" ? Number(req.query.limit) : 20;
    const limit = clamp(Number.isFinite(requestedLimit) ? Math.floor(requestedLimit) : 20, 1, 50);

    res.json(await input.repository.listEpisodes({
      sourceId,
      q,
      statuses: statusValues as TranscriptionStatus[],
      cursor,
      limit
    }));
  }));

  v1.get("/episodes/:episodeId", reads, asyncRoute(async (req, res) => {
    const episode = await input.repository.getEpisodeById(episodeIdParam(req));
    if (!episode) throw new HttpError(404, "not_found");
    res.json({ episode, transcriptionStatus: episode.transcriptionStatus });
  }));

  v1.post(
    "/episodes/:episodeId/transcribe",
    limits.middleware("transcribe-episode", 10, HOUR),
    asyncRoute(async (req, res) => {
      const result = await input.repository.requestTranscription(episodeIdParam(req));
      if (!result) throw new HttpError(404, "not_found");
      const response: TranscribeEpisodeResponse = result;
      res.status(result.jobId ? 202 : 200).json(response);
    })
  );

  v1.post(
    "/voice/transcribe",
    limits.middleware("voice-transcribe", 20, MINUTE),
    upload.single("audio"),
    asyncRoute(async (req, res) => {
      if (!req.file?.buffer) throw new HttpError(400, "audio file is required");
      res.json(await input.aiClient.transcribeAudio({
        buffer: req.file.buffer,
        filename: req.file.originalname || "voice-question.webm",
        mimeType: req.file.mimetype || "audio/webm"
      }));
    })
  );

  v1.post("/qa/answer", limits.middleware("qa", 30, MINUTE), asyncRoute(async (req, res) => {
    const questionText = optionalString(req.body?.questionText, "questionText", 1_000);
    if (!questionText) throw new HttpError(400, "questionText is required");
    const episodeId = optionalUuid(req.body?.episodeId, "episodeId");
    const rawPosition = req.body?.positionSec;
    if (rawPosition !== undefined && rawPosition !== null &&
        (typeof rawPosition !== "number" || !Number.isFinite(rawPosition) || rawPosition < 0)) {
      throw new HttpError(400, "positionSec must be a non-negative number");
    }
    const topK = typeof req.body?.topK === "number" && Number.isFinite(req.body.topK)
      ? clamp(Math.floor(req.body.topK), 1, 12)
      : 6;

    res.json(await answerQuestion(
      { repository: input.repository, aiClient: input.aiClient, minGroundingScore: input.minGroundingScore,
        logError: input.logError },
      {
        questionText,
        episodeId,
        positionSec: episodeId && typeof rawPosition === "number" ? rawPosition : undefined,
        history: sanitizeHistory(req.body?.history),
        topK
      }
    ));
  }));

  v1.post("/voice/synthesize", limits.middleware("voice-synthesize", 20, MINUTE), asyncRoute(async (req, res) => {
    const text = typeof req.body?.text === "string" ? req.body.text.trim() : "";
    if (!text) throw new HttpError(400, "text is required");
    if (text.length > 6000) throw new HttpError(400, "text must be at most 6000 characters");
    res.json(await input.aiClient.synthesizeSpeech(text));
  }));

  app.use("/v1", v1);

  app.use((_req, _res, next) => {
    next(new HttpError(404, "not_found"));
  });
  app.use(errorHandler(input.logError));

  return app;
}
