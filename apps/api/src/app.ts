import express, { type NextFunction, type Request, type Response } from "express";
import cors from "cors";
import multer from "multer";
import {
  transcriptionPrompt,
  type LoginResponse,
  type PodcastSearchResponse,
  type QAStreamEvent,
  type SourceListResponse,
  type TranscribeEpisodeResponse,
  type TranscriptionStatus,
  type UsageResponse,
  type User
} from "@podcast/shared-types";
import {
  hashPassword,
  hashToken,
  MIN_PASSWORD_LENGTH,
  newSessionToken,
  SESSION_DAYS,
  verifyAgainstDummy,
  verifyPassword
} from "./auth.js";
import { MediaSigner, sendAudioFile } from "./media.js";
import { answerQuestion, type QaInput } from "./qa-service.js";
import { RateLimiter } from "./rate-limit.js";
import { sanitizeHistory } from "./retrieval.js";
import { errorHandler, HttpError, keysMatch, requestId, requireAdminKey } from "./security.js";
import type { AIClient, PodcastDirectory, Repository } from "./types.js";

/** The identity of requests made with the optional APP_API_KEY service token. */
const SERVICE_USER: User = { id: "service", email: "service@localhost", name: "Service", role: "admin" };
const UNKNOWN_DURATION_SEC = 3600;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STATUSES: TranscriptionStatus[] = ["pending", "queued", "processing", "ready", "failed"];
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

/** Wraps an async handler; with `middleware`, calls next() after it succeeds. */
function asyncRoute(handler: (req: Request, res: Response) => Promise<void>, middleware = false) {
  return (req: Request, res: Response, next: NextFunction) => {
    handler(req, res).then(() => {
      if (middleware) next();
    }, next);
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

function bearerToken(req: Request): string | undefined {
  return /^Bearer\s+(.+)$/i.exec(req.header("authorization") ?? "")?.[1]?.trim();
}

function minutes(seconds: number): number {
  return Math.round(seconds / 6) / 10;
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
  /** Optional service token for scripts; accepted like a session token. */
  appApiKey?: string;
  minGroundingScore: number;
  mediaSigner?: MediaSigner;
  audioStorageDirectory?: string;
  /** Daily transcription limit in seconds; 0 or unset means no limit. */
  dailyTranscriptionSec?: number;
  podcastSearchCountry?: string;
  corsOrigins?: string[];
  trustProxy?: boolean | number | string;
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

  // Signed links for media players, which cannot send an Authorization header.
  app.get("/v1/media/episodes/:episodeId", asyncRoute(async (req, res) => {
    const episodeId = episodeIdParam(req);
    if (!input.mediaSigner || !input.audioStorageDirectory ||
        !input.mediaSigner.verify(episodeId, req.query.exp, req.query.sig)) {
      throw new HttpError(403, "link expired or invalid");
    }
    const audio = await input.repository.getEpisodeAudio(episodeId);
    if (!audio) throw new HttpError(404, "not_found");
    await sendAudioFile(res, input.audioStorageDirectory, audio.file, audio.mimeType, req.header("range"));
  }));

  app.post("/v1/auth/login", limits.middleware("login", 10, 15 * MINUTE), asyncRoute(async (req, res) => {
    const email = optionalString(req.body?.email, "email", 320);
    const password = typeof req.body?.password === "string" ? req.body.password : "";
    if (!email || !password) throw new HttpError(400, "email and password are required");
    const user = await input.repository.findUserForLogin(email);
    const valid = user && !user.disabled
      ? await verifyPassword(password, user.passwordHash)
      : await verifyAgainstDummy(password);
    if (!user || !valid) throw new HttpError(401, "invalid email or password");
    const { token, tokenHash } = newSessionToken();
    const expiresAt = new Date(Date.now() + SESSION_DAYS * 24 * 60 * MINUTE);
    await input.repository.createSession({ userId: user.id, tokenHash, expiresAt });
    const response: LoginResponse = {
      token,
      expiresAt: expiresAt.toISOString(),
      user: { id: user.id, email: user.email, name: user.name, role: user.role }
    };
    res.json(response);
  }));

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

  admin.post("/users", asyncRoute(async (req, res) => {
    const email = optionalString(req.body?.email, "email", 320);
    const name = optionalString(req.body?.name, "name", 200);
    const password = typeof req.body?.password === "string" ? req.body.password : "";
    const role = req.body?.role === "admin" ? "admin" : "user";
    if (!email || !/^[^\s@]+@[^\s@]+$/.test(email)) throw new HttpError(400, "a valid email is required");
    if (!name) throw new HttpError(400, "name is required");
    if (password.length < MIN_PASSWORD_LENGTH) {
      throw new HttpError(400, `password must be at least ${MIN_PASSWORD_LENGTH} characters`);
    }
    res.status(201).json(await input.repository.createUser({
      email, name, role, passwordHash: await hashPassword(password)
    }));
  }));

  admin.post("/episodes/:episodeId/retranscribe", asyncRoute(async (req, res) => {
    const result = await input.repository.retranscribeEpisode(episodeIdParam(req));
    if (!result) throw new HttpError(404, "not_found");
    res.status(202).json(result);
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
  v1.use(asyncRoute(async (req, res) => {
    const token = bearerToken(req);
    if (token && input.appApiKey && keysMatch(token, input.appApiKey)) {
      res.locals.user = SERVICE_USER;
    } else {
      const user = token ? await input.repository.findSessionUser(hashToken(token)) : null;
      if (!user) throw new HttpError(401, "unauthorized");
      res.locals.user = user;
      res.locals.sessionTokenHash = hashToken(token!);
    }
  }, true));
  const reads = limits.middleware("read", 300, MINUTE);

  v1.post("/auth/logout", asyncRoute(async (_req, res) => {
    if (res.locals.sessionTokenHash) await input.repository.deleteSession(res.locals.sessionTokenHash as string);
    res.status(204).end();
  }));

  v1.get("/me", (_req, res) => {
    res.json(res.locals.user as User);
  });

  const remainingSeconds = async () =>
    (input.dailyTranscriptionSec ?? 0) - (await input.repository.getTranscribedSecondsToday());

  v1.get("/usage", reads, asyncRoute(async (_req, res) => {
    const usedSec = await input.repository.getTranscribedSecondsToday();
    const limitSec = input.dailyTranscriptionSec ?? 0;
    const response: UsageResponse = {
      date: new Date().toISOString().slice(0, 10),
      usedMinutes: minutes(usedSec),
      limitMinutes: minutes(limitSec),
      remainingMinutes: minutes(Math.max(0, limitSec - usedSec))
    };
    res.json(response);
  }));

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

  v1.patch("/sources/:sourceId", limits.middleware("update-source", 60, HOUR), asyncRoute(async (req, res) => {
    const sourceId = String(req.params.sourceId ?? "");
    if (!UUID_PATTERN.test(sourceId)) throw new HttpError(404, "not_found");
    if (typeof req.body?.autoTranscribe !== "boolean") throw new HttpError(400, "autoTranscribe must be true or false");
    const source = await input.repository.updateSource(sourceId, { autoTranscribe: req.body.autoTranscribe });
    if (!source) throw new HttpError(404, "not_found");
    res.json(source);
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
      const episodeId = episodeIdParam(req);
      if (input.dailyTranscriptionSec) {
        const episode = await input.repository.getEpisodeById(episodeId);
        if (!episode) throw new HttpError(404, "not_found");
        const needed = episode.durationSec ?? UNKNOWN_DURATION_SEC;
        if (episode.transcriptionStatus !== "ready" && needed > await remainingSeconds()) {
          throw new HttpError(429, "Today's transcription limit is used up", {}, "transcription_budget_exceeded");
        }
      }
      const result = await input.repository.requestTranscription(episodeId);
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
      // Names from the episode help the model spell them in the question.
      const episodeId = optionalUuid(req.body?.episodeId, "episodeId");
      const episode = episodeId ? await input.repository.getEpisodeById(episodeId) : null;
      const prompt = episode
        ? transcriptionPrompt({
            show: episode.sourceName,
            title: episode.title,
            text: [episode.description, ...episode.chapters.map((chapter) => chapter.title)].join(" ")
          })
        : undefined;
      res.json(await input.aiClient.transcribeAudio({
        buffer: req.file.buffer,
        filename: req.file.originalname || "voice-question.webm",
        mimeType: req.file.mimetype || "audio/webm",
        prompt
      }));
    })
  );

  const qaLimit = limits.middleware("qa", 30, MINUTE);
  const qaDependencies = {
    repository: input.repository,
    aiClient: input.aiClient,
    minGroundingScore: input.minGroundingScore,
    logError: input.logError
  };

  function parseQuestion(req: Request): QaInput {
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
      // 10 answered every question in scripts/eval/datasets/hard-fork-holmes.json;
      // 6 missed passages in a one-hour conversation, at the same latency.
      : 10;

    return {
      questionText,
      episodeId,
      positionSec: episodeId && typeof rawPosition === "number" ? rawPosition : undefined,
      history: sanitizeHistory(req.body?.history),
      topK
    };
  }

  v1.post("/qa/answer", qaLimit, asyncRoute(async (req, res) => {
    res.json(await answerQuestion(qaDependencies, parseQuestion(req)));
  }));

  /**
   * Server-sent events: status, answer text as it is written, then the full
   * response. Errors before the first event use the normal JSON error format.
   */
  v1.post("/qa/answer/stream", qaLimit, asyncRoute(async (req, res) => {
    const question = parseQuestion(req);
    const abort = new AbortController();
    res.on("close", () => {
      if (!res.writableFinished) abort.abort();
    });
    const send = (event: QAStreamEvent) => {
      if (!res.headersSent) {
        res.status(200);
        res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
        res.setHeader("Cache-Control", "no-cache, no-transform");
        res.setHeader("X-Accel-Buffering", "no");
        res.flushHeaders();
      }
      res.write(`data: ${JSON.stringify(event)}\n\n`);
    };
    try {
      const response = await answerQuestion(qaDependencies, { ...question, onEvent: send, signal: abort.signal });
      send({ type: "done", response });
    } catch (error) {
      if (!res.headersSent) throw error;
      if (abort.signal.aborted) return;
      const id = String(res.locals.requestId ?? "");
      (input.logError ?? console.error)(`Request ${id} failed`, error);
      send(error instanceof HttpError
        ? { type: "error", error: error.message }
        : { type: "error", error: "internal_error", requestId: id });
    }
    res.end();
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
