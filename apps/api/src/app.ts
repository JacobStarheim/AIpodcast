import express, { type NextFunction, type Request, type Response } from "express";
import cors from "cors";
import multer from "multer";
import type { QAResponse } from "@podcast/shared-types";
import type { AIClient, Repository, RetrievedSegment } from "./types.js";
import { hasSufficientGrounding } from "./retrieval.js";

const refusalText = "I do not have enough transcript evidence to answer that confidently.";

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function toCitations(indices: number[], segments: RetrievedSegment[]): RetrievedSegment[] {
  const unique = [...new Set(indices)];
  return unique
    .filter((index) => index >= 0 && index < segments.length)
    .map((index) => segments[index])
    .filter((segment): segment is RetrievedSegment => Boolean(segment));
}

export function createApp(input: {
  repository: Repository;
  aiClient: AIClient;
  adminKey: string;
  minGroundingScore: number;
}) {
  const app = express();
  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: 25 * 1024 * 1024 }
  });

  app.use(cors());
  app.use(express.json({ limit: "2mb" }));

  app.get("/health", (_req, res) => {
    res.json({ ok: true });
  });

  function requireAdmin(req: Request, res: Response, next: NextFunction) {
    const headerKey = req.header("x-admin-key");
    if (!headerKey || headerKey !== input.adminKey) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    next();
  }

  app.post("/v1/admin/sources", requireAdmin, async (req, res, next) => {
    try {
      const name = typeof req.body?.name === "string" ? req.body.name.trim() : "";
      const rssUrl = typeof req.body?.rssUrl === "string" ? req.body.rssUrl.trim() : "";

      if (!name || !rssUrl) {
        res.status(400).json({ error: "name and rssUrl are required" });
        return;
      }

      const source = await input.repository.createSource({ name, rssUrl });
      res.status(201).json(source);
    } catch (error) {
      next(error);
    }
  });

  app.post("/v1/admin/ingest/run", requireAdmin, async (req, res, next) => {
    try {
      const sourceId = typeof req.body?.sourceId === "string" ? req.body.sourceId : undefined;
      const maxEpisodesPerSource =
        typeof req.body?.maxEpisodesPerSource === "number"
          ? clamp(Math.floor(req.body.maxEpisodesPerSource), 1, 100)
          : undefined;

      const job = await input.repository.enqueueIngestJob({
        sourceId,
        maxEpisodesPerSource
      });

      res.status(202).json({ jobId: job.id, status: "queued" });
    } catch (error) {
      next(error);
    }
  });

  app.get("/v1/episodes", async (req, res, next) => {
    try {
      const sourceId = typeof req.query.sourceId === "string" ? req.query.sourceId : undefined;
      const q = typeof req.query.q === "string" ? req.query.q : undefined;
      const cursor = typeof req.query.cursor === "string" ? req.query.cursor : undefined;
      const requestedLimit = typeof req.query.limit === "string" ? Number(req.query.limit) : 20;
      const limit = clamp(Number.isFinite(requestedLimit) ? Math.floor(requestedLimit) : 20, 1, 50);

      const response = await input.repository.listEpisodes({ sourceId, q, cursor, limit });
      res.json(response);
    } catch (error) {
      next(error);
    }
  });

  app.get("/v1/episodes/:episodeId", async (req, res, next) => {
    try {
      const episode = await input.repository.getEpisodeById(req.params.episodeId);
      if (!episode) {
        res.status(404).json({ error: "not_found" });
        return;
      }

      res.json({
        episode,
        transcriptionStatus: episode.transcriptionStatus
      });
    } catch (error) {
      next(error);
    }
  });

  app.post("/v1/voice/transcribe", upload.single("audio"), async (req, res, next) => {
    try {
      if (!req.file?.buffer) {
        res.status(400).json({ error: "audio file is required" });
        return;
      }

      const result = await input.aiClient.transcribeAudio({
        buffer: req.file.buffer,
        filename: req.file.originalname || "voice-question.webm",
        mimeType: req.file.mimetype || "audio/webm"
      });

      res.json(result);
    } catch (error) {
      next(error);
    }
  });

  app.post("/v1/qa/answer", async (req, res, next) => {
    const startedAt = Date.now();

    try {
      const questionText = typeof req.body?.questionText === "string" ? req.body.questionText.trim() : "";
      const episodeId = typeof req.body?.episodeId === "string" ? req.body.episodeId : undefined;
      const topK =
        typeof req.body?.topK === "number"
          ? clamp(Math.floor(req.body.topK), 1, 12)
          : 5;

      if (!questionText) {
        res.status(400).json({ error: "questionText is required" });
        return;
      }

      const questionEmbedding = await input.aiClient.embedText(questionText);
      const segments = await input.repository.searchSegments({
        embedding: questionEmbedding,
        episodeId,
        topK
      });

      const grounding = hasSufficientGrounding(segments, input.minGroundingScore);
      if (!grounding.grounded) {
        const response: QAResponse = {
          answerText: refusalText,
          citations: [],
          grounded: false,
          refusalReason: "insufficient_retrieval_confidence"
        };
        await input.repository.logQaEvent({
          episodeId,
          questionText,
          grounded: false,
          latencyMs: Date.now() - startedAt
        });

        res.json(response);
        return;
      }

      const groundedAnswer = await input.aiClient.answerGrounded({ questionText, segments });
      const citations = toCitations(groundedAnswer.citationIndices, segments);

      if (!groundedAnswer.answerText || citations.length === 0) {
        const response: QAResponse = {
          answerText: refusalText,
          citations: [],
          grounded: false,
          refusalReason: "insufficient_grounded_citations"
        };

        await input.repository.logQaEvent({
          episodeId,
          questionText,
          grounded: false,
          latencyMs: Date.now() - startedAt
        });

        res.json(response);
        return;
      }

      const response: QAResponse = {
        answerText: groundedAnswer.answerText,
        citations,
        grounded: true
      };

      await input.repository.logQaEvent({
        episodeId,
        questionText,
        grounded: true,
        latencyMs: Date.now() - startedAt
      });

      res.json(response);
    } catch (error) {
      next(error);
    }
  });

  app.post("/v1/voice/synthesize", async (req, res, next) => {
    try {
      const text = typeof req.body?.text === "string" ? req.body.text.trim() : "";
      if (!text) {
        res.status(400).json({ error: "text is required" });
        return;
      }
      if (text.length > 6000) {
        res.status(400).json({ error: "text must be at most 6000 characters" });
        return;
      }

      const audio = await input.aiClient.synthesizeSpeech(text);
      res.json(audio);
    } catch (error) {
      next(error);
    }
  });

  app.use((error: unknown, _req: Request, res: Response, _next: NextFunction) => {
    const message = error instanceof Error ? error.message : "Internal Server Error";
    const status = message === "Invalid cursor" ? 400 : 500;
    res.status(status).json({ error: message });
  });

  return app;
}
