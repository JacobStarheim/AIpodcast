import request from "supertest";
import { describe, expect, it } from "vitest";
import type { EpisodeDetail, EpisodeSummary, EpisodeListResponse, Source } from "@podcast/shared-types";
import { createApp } from "../src/app.js";
import type { AIClient, IngestJob, Repository, RetrievedSegment } from "../src/types.js";

class FakeRepository implements Repository {
  private readonly sources: Source[] = [];
  private readonly jobs: IngestJob[] = [];
  private readonly episode: EpisodeDetail = {
    id: "ep_1",
    sourceId: "src_1",
    sourceName: "Demo Source",
    guid: "guid-1",
    title: "Episode One",
    description: "A test episode",
    publishedAt: new Date("2025-02-01T00:00:00Z").toISOString(),
    audioUrl: "https://example.com/ep1.mp3",
    transcriptionStatus: "ready",
    durationSec: 1800
  };

  async createSource(input: { name: string; rssUrl: string }): Promise<Source> {
    const source: Source = {
      id: `src_${this.sources.length + 1}`,
      name: input.name,
      rssUrl: input.rssUrl,
      createdAt: new Date().toISOString()
    };
    this.sources.push(source);
    return source;
  }

  async enqueueIngestJob(input: { sourceId?: string; maxEpisodesPerSource?: number }): Promise<IngestJob> {
    const job: IngestJob = {
      id: `job_${this.jobs.length + 1}`,
      sourceId: input.sourceId ?? null,
      maxEpisodesPerSource: input.maxEpisodesPerSource ?? null,
      status: "queued",
      createdAt: new Date().toISOString()
    };
    this.jobs.push(job);
    return job;
  }

  async listEpisodes(_input: {
    sourceId?: string;
    q?: string;
    limit: number;
    cursor?: string;
  }): Promise<EpisodeListResponse> {
    const summary: EpisodeSummary = {
      id: this.episode.id,
      sourceId: this.episode.sourceId,
      sourceName: this.episode.sourceName,
      title: this.episode.title,
      description: this.episode.description,
      publishedAt: this.episode.publishedAt,
      audioUrl: this.episode.audioUrl,
      transcriptionStatus: this.episode.transcriptionStatus
    };
    return { items: [summary], nextCursor: null };
  }

  async getEpisodeById(episodeId: string): Promise<EpisodeDetail | null> {
    return episodeId === this.episode.id ? this.episode : null;
  }

  async searchSegments(input: {
    embedding: number[];
    episodeId?: string;
    topK: number;
  }): Promise<RetrievedSegment[]> {
    const score = input.embedding[0] ?? 0;
    return [
      {
        segmentId: "seg_1",
        episodeId: input.episodeId ?? this.episode.id,
        episodeTitle: this.episode.title,
        startSec: 120,
        endSec: 152,
        text: "The host explains the prototype architecture and citation strategy.",
        score
      }
    ];
  }

  async logQaEvent(_input: {
    episodeId?: string;
    questionText: string;
    grounded: boolean;
    latencyMs: number;
  }): Promise<void> {
    return;
  }
}

class FakeAIClient implements AIClient {
  async transcribeAudio(): Promise<{ text: string; durationMs: number }> {
    return { text: "What did the host say about architecture?", durationMs: 1800 };
  }

  async embedText(text: string): Promise<number[]> {
    return text.toLowerCase().includes("unsupported") ? [0.1] : [0.9];
  }

  async answerGrounded(): Promise<{ answerText: string; citationIndices: number[] }> {
    return {
      answerText: "The host said the architecture uses transcript-first retrieval with citations.",
      citationIndices: [0]
    };
  }

  async synthesizeSpeech(): Promise<{ audioBase64: string; mimeType: "audio/wav" }> {
    return {
      audioBase64: Buffer.from("fake-audio").toString("base64"),
      mimeType: "audio/wav"
    };
  }
}

describe("API contracts", () => {
  const app = createApp({
    repository: new FakeRepository(),
    aiClient: new FakeAIClient(),
    adminKey: "dev-admin",
    minGroundingScore: 0.45
  });

  it("covers all v1 routes", async () => {
    const unauthorized = await request(app).post("/v1/admin/sources").send({
      name: "Demo",
      rssUrl: "https://example.com/rss"
    });
    expect(unauthorized.status).toBe(401);

    const sourceResponse = await request(app)
      .post("/v1/admin/sources")
      .set("x-admin-key", "dev-admin")
      .send({ name: "Demo", rssUrl: "https://example.com/rss" });
    expect(sourceResponse.status).toBe(201);
    expect(sourceResponse.body.rssUrl).toBe("https://example.com/rss");

    const ingestResponse = await request(app)
      .post("/v1/admin/ingest/run")
      .set("x-admin-key", "dev-admin")
      .send({ maxEpisodesPerSource: 5 });
    expect(ingestResponse.status).toBe(202);
    expect(ingestResponse.body.status).toBe("queued");

    const episodesResponse = await request(app).get("/v1/episodes?limit=10");
    expect(episodesResponse.status).toBe(200);
    expect(episodesResponse.body.items).toHaveLength(1);

    const detailResponse = await request(app).get("/v1/episodes/ep_1");
    expect(detailResponse.status).toBe(200);
    expect(detailResponse.body.transcriptionStatus).toBe("ready");

    const transcribeResponse = await request(app)
      .post("/v1/voice/transcribe")
      .attach("audio", Buffer.from("voice-bytes"), "question.webm");
    expect(transcribeResponse.status).toBe(200);
    expect(transcribeResponse.body.text).toContain("architecture");

    const qaResponse = await request(app).post("/v1/qa/answer").send({
      questionText: "What did the host say?",
      episodeId: "ep_1",
      topK: 5
    });
    expect(qaResponse.status).toBe(200);
    expect(qaResponse.body.grounded).toBe(true);
    expect(qaResponse.body.citations.length).toBeGreaterThan(0);

    const ttsResponse = await request(app).post("/v1/voice/synthesize").send({
      text: "hello"
    });
    expect(ttsResponse.status).toBe(200);
    expect(ttsResponse.body.mimeType).toBe("audio/wav");
  });

  it("refuses when retrieval confidence is weak", async () => {
    const response = await request(app).post("/v1/qa/answer").send({
      questionText: "unsupported question",
      episodeId: "ep_1"
    });

    expect(response.status).toBe(200);
    expect(response.body.grounded).toBe(false);
    expect(response.body.refusalReason).toBe("insufficient_retrieval_confidence");
  });

  it("refuses high-scoring retrieval when the answer has no valid citation", async () => {
    const aiClient = new FakeAIClient();
    aiClient.answerGrounded = async () => ({
      answerText: "This claim has no supporting chunk.",
      citationIndices: [99]
    });
    const appWithUncitedAnswer = createApp({
      repository: new FakeRepository(),
      aiClient,
      adminKey: "dev-admin",
      minGroundingScore: 0.45
    });
    const response = await request(appWithUncitedAnswer).post("/v1/qa/answer").send({
      questionText: "What did the host say?",
      episodeId: "ep_1"
    });
    expect(response.status).toBe(200);
    expect(response.body.grounded).toBe(false);
    expect(response.body.citations).toEqual([]);
    expect(response.body.refusalReason).toBe("insufficient_grounded_citations");
  });

  it("rejects speech text beyond the supported limit", async () => {
    const response = await request(app).post("/v1/voice/synthesize").send({ text: "a".repeat(6001) });
    expect(response.status).toBe(400);
  });
});
