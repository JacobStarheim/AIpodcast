import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import request from "supertest";
import { afterEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { hashPassword, verifyPassword } from "../src/auth.js";
import { MediaSigner } from "../src/media.js";
import {
  APP_KEY,
  AUTH,
  EPISODE_ID,
  FakeAIClient,
  FakeDirectory,
  FakeRepository,
  PENDING_EPISODE_ID,
  SOURCE_ID
} from "./fakes.js";

const directories: string[] = [];

afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function setup(options: { dailySec?: number; withAudio?: boolean } = {}) {
  const repository = new FakeRepository();
  const aiClient = new FakeAIClient();
  const signer = new MediaSigner("test-secret");
  const audioDirectory = await mkdtemp(join(tmpdir(), "api-media-test-"));
  directories.push(audioDirectory);
  if (options.withAudio) {
    await writeFile(join(audioDirectory, `${EPISODE_ID}.mp3`), "0123456789");
    repository.audioFiles.set(EPISODE_ID, { file: `${EPISODE_ID}.mp3`, mimeType: "audio/mpeg" });
  }
  const errors: unknown[] = [];
  const app = createApp({
    repository,
    aiClient,
    podcastDirectory: new FakeDirectory(),
    adminKey: "dev-admin",
    appApiKey: APP_KEY,
    minGroundingScore: 0.45,
    mediaSigner: signer,
    audioStorageDirectory: audioDirectory,
    dailyTranscriptionSec: options.dailySec,
    logError: (_message, error) => errors.push(error)
  });
  return { app, repository, aiClient, signer, errors };
}

async function createUserAndLogin(app: Awaited<ReturnType<typeof setup>>["app"]) {
  const created = await request(app).post("/v1/admin/users").set("x-admin-key", "dev-admin")
    .send({ email: "Ada@Example.com", name: "Ada", password: "correct horse battery" });
  expect(created.status).toBe(201);
  const login = await request(app).post("/v1/auth/login")
    .send({ email: "ada@example.com", password: "correct horse battery" });
  expect(login.status).toBe(200);
  return login.body as { token: string; user: { email: string } };
}

describe("passwords", () => {
  it("hashes with a salt and verifies only the right password", async () => {
    const first = await hashPassword("correct horse battery");
    const second = await hashPassword("correct horse battery");
    expect(first).not.toBe(second);
    expect(first).toMatch(/^scrypt\$16384\$8\$1\$/);
    expect(await verifyPassword("correct horse battery", first)).toBe(true);
    expect(await verifyPassword("wrong", first)).toBe(false);
    expect(await verifyPassword("anything", "md5$abc")).toBe(false);
  });
});

describe("accounts", () => {
  it("logs in, uses the session, and logs out", async () => {
    const { app } = await setup();
    const { token, user } = await createUserAndLogin(app);
    expect(user.email).toBe("Ada@Example.com");

    const me = await request(app).get("/v1/me").set("Authorization", `Bearer ${token}`);
    expect(me.body).toMatchObject({ name: "Ada", role: "user" });
    expect((await request(app).get("/v1/sources").set("Authorization", `Bearer ${token}`)).status).toBe(200);

    expect((await request(app).post("/v1/auth/logout").set("Authorization", `Bearer ${token}`)).status).toBe(204);
    expect((await request(app).get("/v1/me").set("Authorization", `Bearer ${token}`)).status).toBe(401);
  });

  it("rejects wrong passwords and unknown users the same way", async () => {
    const { app } = await setup();
    await createUserAndLogin(app);
    const wrong = await request(app).post("/v1/auth/login").send({ email: "ada@example.com", password: "nope nope nope" });
    const unknown = await request(app).post("/v1/auth/login").send({ email: "eve@example.com", password: "nope nope nope" });
    expect([wrong.status, unknown.status]).toEqual([401, 401]);
    expect(wrong.body).toEqual(unknown.body);
  });

  it("validates new accounts and refuses duplicates", async () => {
    const { app } = await setup();
    const admin = (body: object) => request(app).post("/v1/admin/users").set("x-admin-key", "dev-admin").send(body);
    expect((await admin({ email: "not-an-email", name: "X", password: "long enough pw" })).status).toBe(400);
    expect((await admin({ email: "a@b.c", name: "X", password: "short" })).status).toBe(400);
    expect((await admin({ email: "a@b.c", name: "X", password: "long enough pw" })).status).toBe(201);
    expect((await admin({ email: "A@B.C", name: "Y", password: "long enough pw" })).status).toBe(409);
    expect((await request(app).post("/v1/admin/users").send({})).status).toBe(401);
  });

  it("limits login attempts per client", async () => {
    const { app } = await setup();
    for (let attempt = 0; attempt < 10; attempt += 1) {
      await request(app).post("/v1/auth/login").send({ email: "x@y.z", password: "whatever-pw" });
    }
    const limited = await request(app).post("/v1/auth/login").send({ email: "x@y.z", password: "whatever-pw" });
    expect(limited.status).toBe(429);
  });
});

describe("audio links", () => {
  it("serves the stored file through a signed link with ranges", async () => {
    const { app, signer } = await setup({ withAudio: true });
    const url = signer.url(EPISODE_ID);
    const full = await request(app).get(url);
    expect(full.status).toBe(200);
    expect(full.headers["content-type"]).toBe("audio/mpeg");
    expect(full.headers["accept-ranges"]).toBe("bytes");

    const part = await request(app).get(url).set("Range", "bytes=2-5");
    expect(part.status).toBe(206);
    expect(part.headers["content-range"]).toBe("bytes 2-5/10");
    expect(Buffer.from(part.body as Buffer).toString()).toBe("2345");

    expect((await request(app).get(url).set("Range", "bytes=20-")).status).toBe(416);
  });

  it("refuses unsigned, tampered and expired links", async () => {
    const { app } = await setup({ withAudio: true });
    const path = `/v1/media/episodes/${EPISODE_ID}`;
    expect((await request(app).get(path)).status).toBe(403);
    const valid = new MediaSigner("test-secret").url(EPISODE_ID);
    expect((await request(app).get(valid.replace("sig=", "sig=x"))).status).toBe(403);
    const expired = new MediaSigner("test-secret", "", 60, () => Date.now() - 3_600_000).url(EPISODE_ID);
    expect((await request(app).get(expired)).status).toBe(403);
    const otherSecret = new MediaSigner("another-secret").url(EPISODE_ID);
    expect((await request(app).get(otherSecret)).status).toBe(403);
  });

  it("builds absolute links when a public origin is configured", () => {
    const url = new MediaSigner("s", "https://podcast.example.com/", 60, () => 0).url(EPISODE_ID);
    expect(url).toMatch(new RegExp(`^https://podcast\\.example\\.com/v1/media/episodes/${EPISODE_ID}\\?exp=60&sig=`));
  });
});

describe("daily transcription limit", () => {
  it("reports usage and refuses requests that would exceed it", async () => {
    const { app, repository } = await setup({ dailySec: 3600 });
    repository.transcribedSeconds = 1800;
    const usage = await request(app).get("/v1/usage").set(AUTH);
    expect(usage.body).toMatchObject({ usedMinutes: 30, limitMinutes: 60, remainingMinutes: 30 });

    // The pending episode has no duration, so an hour is assumed.
    const refused = await request(app).post(`/v1/episodes/${PENDING_EPISODE_ID}/transcribe`).set(AUTH);
    expect(refused.status).toBe(429);
    expect(refused.body).toMatchObject({ code: "transcription_budget_exceeded" });

    repository.transcribedSeconds = 0;
    expect((await request(app).post(`/v1/episodes/${PENDING_EPISODE_ID}/transcribe`).set(AUTH)).status).toBe(202);
  });
});

describe("sources and admin", () => {
  it("turns automatic transcription on and off", async () => {
    const { app } = await setup();
    await request(app).post("/v1/sources").set(AUTH).send({ rssUrl: "https://feeds.example.com/x" });
    const on = await request(app).patch(`/v1/sources/${SOURCE_ID}`).set(AUTH).send({ autoTranscribe: true });
    expect(on.body.autoTranscribe).toBe(true);
    expect((await request(app).patch(`/v1/sources/${SOURCE_ID}`).set(AUTH).send({ autoTranscribe: "yes" })).status).toBe(400);
    expect((await request(app).patch(`/v1/sources/${EPISODE_ID}`).set(AUTH).send({ autoTranscribe: true })).status).toBe(404);
  });

  it("queues a re-transcription", async () => {
    const { app, repository } = await setup();
    const response = await request(app).post(`/v1/admin/episodes/${EPISODE_ID}/retranscribe`).set("x-admin-key", "dev-admin");
    expect(response.status).toBe(202);
    expect(repository.retranscribed).toEqual([EPISODE_ID]);
  });
});

describe("voice questions", () => {
  it("passes the episode's names to transcription", async () => {
    const { app, aiClient, repository } = await setup();
    repository.episodes[0]!.description = "<p>Ada Lovelace talks with Grace Hopper.</p>";
    await request(app).post("/v1/voice/transcribe").set(AUTH)
      .field("episodeId", EPISODE_ID).attach("audio", Buffer.from("x"), "q.m4a");
    await request(app).post("/v1/voice/transcribe").set(AUTH).attach("audio", Buffer.from("x"), "q.m4a");
    expect(aiClient.transcribePrompts).toEqual([
      "Demo Source. Episode One. Ada Lovelace, Grace Hopper.",
      undefined
    ]);
  });
});

function parseEvents(body: string): { type: string; [key: string]: unknown }[] {
  return body.split("\n\n").filter(Boolean).map((block) => JSON.parse(block.replace(/^data: /, "")));
}

describe("streamed answers", () => {
  it("sends status, text deltas and the final response", async () => {
    const { app } = await setup();
    const response = await request(app).post("/v1/qa/answer/stream").set(AUTH)
      .send({ questionText: "What did the host say?", episodeId: EPISODE_ID });
    expect(response.status).toBe(200);
    expect(response.headers["content-type"]).toBe("text/event-stream; charset=utf-8");
    const events = parseEvents(response.text);
    expect(events.map((event) => event.type)).toEqual(
      ["status", "status", ...events.slice(2, -1).map(() => "delta"), "done"]
    );
    const text = events.filter((event) => event.type === "delta").map((event) => event.text).join("");
    const done = events.at(-1) as { response: { answerText: string; grounded: boolean } };
    expect(text).toBe(done.response.answerText);
    expect(done.response.grounded).toBe(true);
  });

  it("uses normal errors before streaming and an error event after", async () => {
    const { app, aiClient, errors } = await setup();
    expect((await request(app).post("/v1/qa/answer/stream").set(AUTH).send({})).status).toBe(400);

    aiClient.answerGrounded = async () => {
      throw new Error("upstream exploded with secrets");
    };
    const response = await request(app).post("/v1/qa/answer/stream").set(AUTH)
      .send({ questionText: "What did the host say?", episodeId: EPISODE_ID });
    const last = parseEvents(response.text).at(-1);
    expect(last).toMatchObject({ type: "error", error: "internal_error" });
    expect(response.text).not.toContain("secrets");
    expect(errors).toHaveLength(1);
  });
});
