import request from "supertest";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { MemoryRateLimitStore, RateLimiter } from "../src/rate-limit.js";
import {
  APP_KEY,
  AUTH,
  EPISODE_ID,
  FakeAIClient,
  FakeDirectory,
  FakeRepository,
  MISSING_ID,
  PENDING_EPISODE_ID
} from "./fakes.js";

function setup(overrides: { aiClient?: FakeAIClient; rateLimiter?: RateLimiter } = {}) {
  const repository = new FakeRepository();
  const aiClient = overrides.aiClient ?? new FakeAIClient();
  const directory = new FakeDirectory();
  const errors: unknown[] = [];
  const app = createApp({
    repository,
    aiClient,
    podcastDirectory: directory,
    adminKey: "dev-admin",
    appApiKey: APP_KEY,
    minGroundingScore: 0.45,
    podcastSearchCountry: "NO",
    rateLimiter: overrides.rateLimiter,
    logError: (_message, error) => errors.push(error)
  });
  return { app, repository, aiClient, directory, errors };
}

describe("API contracts", () => {
  it("covers all v1 routes", async () => {
    const { app } = setup();
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

    const episodesResponse = await request(app).get("/v1/episodes?limit=10").set(AUTH);
    expect(episodesResponse.status).toBe(200);
    expect(episodesResponse.body.items).toHaveLength(2);

    const detailResponse = await request(app).get(`/v1/episodes/${EPISODE_ID}`).set(AUTH);
    expect(detailResponse.status).toBe(200);
    expect(detailResponse.body.transcriptionStatus).toBe("ready");
    expect(detailResponse.body.episode.chapters).toHaveLength(1);

    const transcribeResponse = await request(app)
      .post("/v1/voice/transcribe")
      .set(AUTH)
      .attach("audio", Buffer.from("voice-bytes"), "question.webm");
    expect(transcribeResponse.status).toBe(200);
    expect(transcribeResponse.body.text).toContain("architecture");

    const qaResponse = await request(app).post("/v1/qa/answer").set(AUTH).send({
      questionText: "What did the host say?",
      episodeId: EPISODE_ID,
      topK: 5
    });
    expect(qaResponse.status).toBe(200);
    expect(qaResponse.body.grounded).toBe(true);
    expect(qaResponse.body.citations[0]).toMatchObject({ kind: "segment", episodeId: EPISODE_ID });

    const ttsResponse = await request(app).post("/v1/voice/synthesize").set(AUTH).send({
      text: "hello"
    });
    expect(ttsResponse.status).toBe(200);
    expect(ttsResponse.body.mimeType).toBe("audio/wav");
  });

  it("requires a session or the service key on every v1 route except health", async () => {
    const { app } = setup();
    expect((await request(app).get("/health")).status).toBe(200);
    for (const [method, path] of [
      ["get", "/v1/episodes"],
      ["get", "/v1/sources"],
      ["get", "/v1/podcasts/search?q=tech"],
      ["post", "/v1/qa/answer"],
      ["post", "/v1/voice/synthesize"],
      ["post", `/v1/episodes/${PENDING_EPISODE_ID}/transcribe`]
    ] as const) {
      const missing = await request(app)[method](path);
      expect(missing.status, `${method} ${path}`).toBe(401);
      const wrong = await request(app)[method](path).set("Authorization", "Bearer wrong");
      expect(wrong.status, `${method} ${path}`).toBe(401);
    }
  });

  it("refuses when retrieval confidence is weak", async () => {
    const { app } = setup();
    const response = await request(app).post("/v1/qa/answer").set(AUTH).send({
      questionText: "unsupported question",
      episodeId: EPISODE_ID
    });

    expect(response.status).toBe(200);
    expect(response.body.grounded).toBe(false);
    expect(response.body.refusalReason).toBe("insufficient_retrieval_confidence");
  });

  it("refuses high-scoring retrieval when the answer has no valid citation", async () => {
    const aiClient = new FakeAIClient();
    aiClient.answerGrounded = async () => ({
      answerText: "This claim has no supporting chunk.",
      citations: [{ index: 99, quote: "" }]
    });
    const { app } = setup({ aiClient });
    const response = await request(app).post("/v1/qa/answer").set(AUTH).send({
      questionText: "What did the host say?",
      episodeId: EPISODE_ID
    });
    expect(response.status).toBe(200);
    expect(response.body.grounded).toBe(false);
    expect(response.body.citations).toEqual([]);
    expect(response.body.refusalReason).toBe("insufficient_grounded_citations");
  });

  it("validates question input", async () => {
    const { app } = setup();
    const cases = [
      [{}, 400],
      [{ questionText: "a".repeat(1001) }, 400],
      [{ questionText: "Q", episodeId: "not-a-uuid" }, 400],
      [{ questionText: "Q", episodeId: EPISODE_ID, positionSec: -1 }, 400],
      [{ questionText: "Q", episodeId: MISSING_ID }, 404],
      [{ questionText: "Q", episodeId: PENDING_EPISODE_ID }, 409]
    ] as const;
    for (const [body, status] of cases) {
      const response = await request(app).post("/v1/qa/answer").set(AUTH).send(body);
      expect(response.status, JSON.stringify(body)).toBe(status);
      expect(typeof response.body.error).toBe("string");
    }
  });

  it("rejects speech text beyond the supported limit", async () => {
    const { app } = setup();
    const response = await request(app).post("/v1/voice/synthesize").set(AUTH).send({ text: "a".repeat(6001) });
    expect(response.status).toBe(400);
  });

  it("filters episodes by status and rejects unknown statuses", async () => {
    const { app, repository } = setup();
    const ready = await request(app).get("/v1/episodes?status=ready&q=proto").set(AUTH);
    expect(ready.status).toBe(200);
    expect(ready.body.items.map((item: { id: string }) => item.id)).toEqual([EPISODE_ID]);
    expect(repository.listQueries.at(-1)).toMatchObject({ statuses: ["ready"], q: "proto", limit: 20 });

    await request(app).get("/v1/episodes?status=pending,failed&status=queued").set(AUTH);
    expect(repository.listQueries.at(-1)?.statuses).toEqual(["pending", "failed", "queued"]);

    expect((await request(app).get("/v1/episodes?status=done").set(AUTH)).status).toBe(400);
    expect((await request(app).get("/v1/episodes/not-a-uuid").set(AUTH)).status).toBe(404);
    expect((await request(app).get(`/v1/episodes/${MISSING_ID}`).set(AUTH)).status).toBe(404);
  });

  it("searches the podcast directory", async () => {
    const { app, directory } = setup();
    const response = await request(app).get("/v1/podcasts/search?q=hard%20fork").set(AUTH);
    expect(response.status).toBe(200);
    expect(response.body.items[0]).toMatchObject({ title: "Hard Fork", feedUrl: "https://feeds.example.com/hardfork" });
    expect(directory.calls).toEqual([{ term: "hard fork", country: "NO" }]);

    await request(app).get("/v1/podcasts/search?q=news&country=us").set(AUTH);
    expect(directory.calls.at(-1)).toEqual({ term: "news", country: "US" });
    expect((await request(app).get("/v1/podcasts/search?q=x").set(AUTH)).status).toBe(400);
  });

  it("reports directory failures without leaking details", async () => {
    const { app, directory, errors } = setup();
    directory.search = async () => {
      throw new Error("getaddrinfo ENOTFOUND itunes.apple.com");
    };
    const response = await request(app).get("/v1/podcasts/search?q=news").set(AUTH);
    expect(response.status).toBe(502);
    expect(JSON.stringify(response.body)).not.toContain("ENOTFOUND");
    expect(errors).toHaveLength(1);
  });

  it("adds a podcast once and lists it", async () => {
    const { app } = setup();
    const body = { rssUrl: "https://feeds.example.com/hardfork", name: "Hard Fork", imageUrl: "https://img.example.com/hf.jpg" };
    const created = await request(app).post("/v1/sources").set(AUTH).send(body);
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({ name: "Hard Fork", lastJob: { status: "queued" } });

    const again = await request(app).post("/v1/sources").set(AUTH).send(body);
    expect(again.status).toBe(200);

    const list = await request(app).get("/v1/sources").set(AUTH);
    expect(list.body.items).toHaveLength(1);

    for (const invalid of [{}, { rssUrl: "ftp://example.com/feed" }, { rssUrl: "not a url" },
      { rssUrl: "https://ok.example.com/rss", imageUrl: "javascript:alert(1)" }]) {
      expect((await request(app).post("/v1/sources").set(AUTH).send(invalid)).status, JSON.stringify(invalid)).toBe(400);
    }
  });

  it("queues transcription of one episode, once", async () => {
    const { app } = setup();
    const first = await request(app).post(`/v1/episodes/${PENDING_EPISODE_ID}/transcribe`).set(AUTH);
    expect(first.status).toBe(202);
    expect(first.body).toMatchObject({ jobId: "job_transcribe", episode: { transcriptionStatus: "queued" } });

    const second = await request(app).post(`/v1/episodes/${PENDING_EPISODE_ID}/transcribe`).set(AUTH);
    expect(second.status).toBe(200);
    expect(second.body.jobId).toBeNull();

    expect((await request(app).post(`/v1/episodes/${MISSING_ID}/transcribe`).set(AUTH)).status).toBe(404);
  });

  it("limits request rates per client with Retry-After", async () => {
    let now = 0;
    const { app } = setup({ rateLimiter: new RateLimiter(new MemoryRateLimitStore(() => now), () => now) });
    for (let index = 0; index < 20; index += 1) {
      expect((await request(app).post("/v1/voice/synthesize").set(AUTH).send({ text: "hi" })).status).toBe(200);
    }
    const limited = await request(app).post("/v1/voice/synthesize").set(AUTH).send({ text: "hi" });
    expect(limited.status).toBe(429);
    expect(limited.headers["retry-after"]).toBe("60");
    // Other routes have their own budget.
    expect((await request(app).get("/v1/sources").set(AUTH)).status).toBe(200);

    now = 60_001;
    expect((await request(app).post("/v1/voice/synthesize").set(AUTH).send({ text: "hi" })).status).toBe(200);
  });

  it("hides internal error details and returns a request id", async () => {
    const aiClient = new FakeAIClient();
    aiClient.synthesizeSpeech = async () => {
      throw new Error("connect ECONNREFUSED 10.0.0.5:5432 password=secret");
    };
    const { app, errors } = setup({ aiClient });
    const response = await request(app).post("/v1/voice/synthesize").set(AUTH).send({ text: "hi" });
    expect(response.status).toBe(500);
    expect(response.body).toEqual({ error: "internal_error", requestId: expect.any(String) });
    expect(response.headers["x-request-id"]).toBe(response.body.requestId);
    expect(errors).toHaveLength(1);
  });

  it("returns client errors for malformed bodies, large uploads and unknown routes", async () => {
    const { app } = setup();
    const badJson = await request(app).post("/v1/qa/answer").set(AUTH)
      .set("Content-Type", "application/json").send("{not json");
    expect(badJson.status).toBe(400);

    const tooLarge = await request(app).post("/v1/voice/transcribe").set(AUTH)
      .attach("audio", Buffer.alloc(25 * 1024 * 1024 + 1), "big.wav");
    expect(tooLarge.status).toBe(413);

    expect((await request(app).get("/v1/nope").set(AUTH)).status).toBe(404);
  });

  it("does not send CORS headers unless origins are configured", async () => {
    const { app } = setup();
    const response = await request(app).get("/health").set("Origin", "https://evil.example.com");
    expect(response.headers["access-control-allow-origin"]).toBeUndefined();
  });
});
