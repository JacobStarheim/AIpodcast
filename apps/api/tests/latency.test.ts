import request from "supertest";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import type { AIClient, IngestJob, Repository, RetrievedSegment } from "../src/types.js";
import type { EpisodeDetail, EpisodeListResponse, Source } from "@podcast/shared-types";

class LatencyRepository implements Repository {
  async createSource(): Promise<Source> {
    throw new Error("not_used");
  }

  async enqueueIngestJob(): Promise<IngestJob> {
    throw new Error("not_used");
  }

  async listEpisodes(): Promise<EpisodeListResponse> {
    return { items: [], nextCursor: null };
  }

  async getEpisodeById(): Promise<EpisodeDetail | null> {
    return null;
  }

  async searchSegments(): Promise<RetrievedSegment[]> {
    return [
      {
        segmentId: "seg-latency",
        episodeId: "ep-latency",
        episodeTitle: "Latency",
        startSec: 30,
        endSec: 42,
        text: "Latency benchmark segment",
        score: 0.99
      }
    ];
  }

  async logQaEvent(): Promise<void> {
    return;
  }
}

class LatencyAiClient implements AIClient {
  async transcribeAudio(): Promise<{ text: string; durationMs: number }> {
    await new Promise((resolve) => setTimeout(resolve, 20));
    return { text: "question", durationMs: 20 };
  }

  async embedText(): Promise<number[]> {
    await new Promise((resolve) => setTimeout(resolve, 40));
    return [0.98];
  }

  async answerGrounded(): Promise<{ answerText: string; citationIndices: number[] }> {
    await new Promise((resolve) => setTimeout(resolve, 70));
    return { answerText: "Latency answer", citationIndices: [0] };
  }

  async synthesizeSpeech(): Promise<{ audioBase64: string; mimeType: "audio/mpeg" }> {
    await new Promise((resolve) => setTimeout(resolve, 50));
    return { audioBase64: Buffer.from("ok").toString("base64"), mimeType: "audio/mpeg" };
  }
}

describe("Latency target", () => {
  it("keeps mocked QA+TTS path under 4 seconds", async () => {
    const app = createApp({
      repository: new LatencyRepository(),
      aiClient: new LatencyAiClient(),
      adminKey: "dev-admin",
      minGroundingScore: 0.45
    });

    const start = Date.now();
    const qa = await request(app).post("/v1/qa/answer").send({
      questionText: "latency test"
    });
    expect(qa.status).toBe(200);
    expect(qa.body.grounded).toBe(true);

    const tts = await request(app).post("/v1/voice/synthesize").send({ text: qa.body.answerText });
    expect(tts.status).toBe(200);

    const elapsed = Date.now() - start;
    expect(elapsed).toBeLessThan(4000);
  });
});
