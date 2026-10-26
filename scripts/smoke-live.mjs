import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import dotenv from "dotenv";
import pg from "pg";
import {
  assertLoopbackUrl, audioDuration, demoDirectory, demoGuid, demoSourceName, demoTitle,
  prepareDemoFixture, repositoryRoot, unsupportedQuestion
} from "./demo-fixture.mjs";

// This is intentionally a live, paid integration check. It uses the running
// API/worker, real Postgres, and the OpenAI configuration in those services.
// No model stubs or hand-written transcripts/embeddings are inserted.
const envPath = join(repositoryRoot, "apps", "api", ".env");
let fileEnv = {};
try {
  fileEnv = dotenv.parse(await readFile(envPath));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
const config = { ...fileEnv, ...process.env };
const apiOrigin = assertLoopbackUrl(
  config.API_BASE_URL || `http://127.0.0.1:${config.PORT || 4000}`, "API_BASE_URL"
);
const demoOrigin = assertLoopbackUrl(
  config.DEMO_BASE_URL || `http://127.0.0.1:${config.DEMO_PORT || 4100}`, "DEMO_BASE_URL"
);
const rssUrl = `${demoOrigin}/feed.xml`;
const reportPath = join(repositoryRoot, ".local", "smoke-report.json");
const report = { startedAt: new Date().toISOString(), apiOrigin, rssUrl, checks: [] };
let pool;
let lock;

function redact(value) {
  let text = String(value);
  for (const name of ["OPENAI_API_KEY", "ADMIN_KEY", "APP_API_KEY", "DATABASE_URL"]) {
    if (config[name]) text = text.replaceAll(config[name], "[redacted]");
  }
  return text.replace(/sk-[\w-]+/g, "[redacted]");
}

async function request(path, { body, admin = false, form } = {}) {
  const headers = {};
  if (admin) headers["x-admin-key"] = config.ADMIN_KEY;
  else if (path !== "/health") headers.Authorization = `Bearer ${config.APP_API_KEY}`;
  if (body) headers["Content-Type"] = "application/json";
  const response = await fetch(`${apiOrigin}${path}`, {
    method: body || form ? "POST" : "GET",
    headers,
    body: form || (body ? JSON.stringify(body) : undefined),
    signal: AbortSignal.timeout(180_000)
  });
  const raw = await response.text();
  let result;
  try { result = JSON.parse(raw); }
  catch { throw new Error(`${path}: expected JSON, got HTTP ${response.status}.`); }
  if (!response.ok) {
    throw new Error(`${path}: HTTP ${response.status}: ${redact(result.error || raw)}`);
  }
  return result;
}

function pass(name, details = {}) {
  report.checks.push({ name, passed: true, ...details });
  console.log(`PASS ${name}`);
}

async function checkSpeech(text, filename, label) {
  const speech = await request("/v1/voice/synthesize", { body: { text } });
  assert.equal(speech.mimeType, "audio/wav", "Upgraded speech must return WAV audio");
  assert.equal(typeof speech.audioBase64, "string");
  const audio = Buffer.from(speech.audioBase64, "base64");
  assert.ok(audio.length > 1024, "Synthesized speech must contain audio samples");
  assert.equal(audio.toString("ascii", 0, 4), "RIFF");
  assert.equal(audio.toString("ascii", 8, 12), "WAVE");
  const audioPath = join(demoDirectory, filename);
  await writeFile(audioPath, audio);
  const durationSec = audioDuration(audioPath);
  assert.ok(durationSec >= 0.5 && durationSec < 120,
    "Synthesized answer duration must be plausible");
  pass(label, {
    text, mimeType: speech.mimeType, bytes: audio.length, durationSec, path: audioPath
  });
}

async function ensureEpisode() {
  // Read-only DB queries identify existing demo records and worker failures.
  // All application writes go through the same admin API used during setup.
  const sources = await pool.query(
    "SELECT id, active FROM rss_sources WHERE rss_url = $1 ORDER BY created_at ASC", [rssUrl]
  );
  let source = sources.rows.find((row) => row.active);
  if (!source && sources.rows.length) {
    throw new Error("The demo RSS source exists but is inactive. Reactivate it before running this test.");
  }
  if (!source) {
    source = await request("/v1/admin/sources", {
      admin: true, body: { name: demoSourceName, rssUrl }
    });
  }
  report.sourceId = source.id;
  let episodes = await request(`/v1/episodes?sourceId=${encodeURIComponent(source.id)}&limit=50`);
  let episode = episodes.items.find((item) => item.title === demoTitle);
  let job;
  if (episode?.transcriptionStatus !== "ready") {
    const existingJobs = await pool.query(
      `SELECT id, status FROM ingest_jobs WHERE source_id = $1
       AND status IN ('queued', 'processing') ORDER BY created_at DESC LIMIT 1`,
      [source.id]
    );
    job = existingJobs.rows[0];
    if (!job) {
      const enqueued = await request("/v1/admin/ingest/run", {
        admin: true, body: { sourceId: source.id, maxEpisodesPerSource: 1 }
      });
      job = { id: enqueued.jobId, status: enqueued.status };
    }
    report.jobId = job.id;
    console.log(`Waiting for real transcription and embeddings (job ${job.id})…`);
  }
  const deadline = Date.now() + 12 * 60_000;
  let lastStatus;
  while (Date.now() < deadline) {
    episodes = await request(`/v1/episodes?sourceId=${encodeURIComponent(source.id)}&limit=50`);
    episode = episodes.items.find((item) => item.title === demoTitle);
    const jobResult = job
      ? await pool.query("SELECT status, error FROM ingest_jobs WHERE id = $1", [job.id])
      : { rows: [] };
    const status = `${jobResult.rows[0]?.status || "reused"}/${episode?.transcriptionStatus || "awaiting episode"}`;
    if (status !== lastStatus) console.log(`Ingest: ${status}`);
    lastStatus = status;
    if (jobResult.rows[0]?.status === "failed") {
      throw new Error(`Ingest failed: ${redact(jobResult.rows[0].error)}`);
    }
    if (episode?.transcriptionStatus === "ready") {
      const detail = await request(`/v1/episodes/${episode.id}`);
      assert.equal(detail.episode.guid, demoGuid);
      assert.ok(detail.episode.durationSec >= 40 && detail.episode.durationSec <= 70,
        "Episode should report the known 40–70 second duration");
      report.episodeId = episode.id;
      pass("RSS import, transcription and embeddings", {
        episodeId: episode.id, durationSec: detail.episode.durationSec,
        reused: !job
      });
      return detail.episode;
    }
    if (jobResult.rows[0]?.status === "completed") {
      throw new Error(`Ingest completed but demo episode is ${episode?.transcriptionStatus || "missing"}.`);
    }
    await delay(2000);
  }
  throw new Error("Timed out after 12 minutes waiting for the worker. Check the worker process and its logs.");
}

try {
  assert.ok(config.ADMIN_KEY, `Set ADMIN_KEY in ${envPath} or the environment.`);
  assert.ok(config.APP_API_KEY, `Set APP_API_KEY in ${envPath} or the environment.`);
  const fixture = await prepareDemoFixture();
  const health = await request("/health");
  assert.equal(health.ok, true);
  const fixtureHealth = await fetch(`${demoOrigin}/health`, {
    signal: AbortSignal.timeout(5000)
  }).then((response) => response.json());
  assert.equal(fixtureHealth.guid, demoGuid, "Start npm run demo:serve before the live test.");
  pass("API and local demo server reachable");

  const range = await fetch(`${demoOrigin}/aurora.mp3`, {
    headers: { Range: "bytes=0-31" },
    signal: AbortSignal.timeout(5000)
  });
  assert.equal(range.status, 206);
  assert.equal((await range.arrayBuffer()).byteLength, 32);
  pass("Episode audio supports seeking with HTTP Range");

  pool = new pg.Pool({
    connectionString: config.DATABASE_URL ||
      "postgresql://podcast:podcast@localhost:5432/podcast_ai",
    max: 2, connectionTimeoutMillis: 5000
  });
  lock = await pool.connect();
  const acquired = await lock.query(
    "SELECT pg_try_advisory_lock(hashtext($1)) AS acquired", [rssUrl]
  );
  assert.equal(acquired.rows[0].acquired, true, "Another live smoke test is already using this demo.");
  const episode = await ensureEpisode();

  const form = new FormData();
  form.append("audio", new Blob([await readFile(fixture.questionPath)], {
    type: "audio/wav"
  }), "question.wav");
  const transcription = await request("/v1/voice/transcribe", { form });
  assert.equal(typeof transcription.text, "string");
  assert.match(transcription.text, /sensors?/i, "Spoken sensor question was not transcribed correctly");
  assert.match(transcription.text, /aurora/i, "Spoken ship name was not transcribed correctly");
  pass("Real spoken question transcription", { text: transcription.text });

  // Feed the actual recognized text onward, matching the mobile voice flow.
  const answer = await request("/v1/qa/answer", {
    body: { episodeId: episode.id, questionText: transcription.text }
  });
  assert.equal(answer.grounded, true, "Known sensor fact must produce a grounded answer");
  assert.match(answer.answerText, /\b24\b|\btwenty[- ]four\b/i, "Answer must name the 24 sensors");
  assert.ok(Array.isArray(answer.citations) && answer.citations.length > 0);
  for (const citation of answer.citations) {
    assert.equal(citation.episodeId, episode.id);
    assert.ok(Number.isFinite(citation.startSec) && citation.startSec >= 0);
    assert.ok(Number.isFinite(citation.endSec) && citation.endSec > citation.startSec);
    assert.ok(citation.endSec <= fixture.durationSec + 1);
    assert.equal(typeof citation.text, "string");
    assert.ok(citation.text.trim().length > 0);
  }
  pass("Grounded answer and playable citation timestamps", {
    question: transcription.text, answer: answer.answerText, citations: answer.citations
  });

  const unsupported = await request("/v1/qa/answer", {
    body: { episodeId: episode.id, questionText: unsupportedQuestion }
  });
  assert.equal(unsupported.grounded, false, "The captain's name is absent from the episode");
  assert.deepEqual(unsupported.citations, []);
  pass("Unsupported question refused", {
    question: unsupportedQuestion, answer: unsupported.answerText,
    reason: unsupported.refusalReason
  });

  await checkSpeech(answer.answerText, "answer.wav",
    "Real synthesized answer has valid playable WAV audio");
  await checkSpeech(
    "Forskningsskipet Aurora har 24 sensorer og reiser fra Tromsø på tirsdag.",
    "answer-norwegian.wav", "Norwegian speech with numeric text has valid playable WAV audio"
  );
  report.passed = true;
  report.finishedAt = new Date().toISOString();
  console.log(`Live voice flow passed for "${demoTitle}".`);
  console.log(`Evidence: ${reportPath}`);
} catch (error) {
  report.passed = false;
  report.finishedAt = new Date().toISOString();
  report.error = redact(error.message);
  console.error(`FAIL ${report.error}`);
  console.error("This live test does not mock failures. Check running services, model access, and billing.");
  process.exitCode = 1;
} finally {
  if (lock) {
    // Session-scoped advisory locks are released by disconnecting this client.
    lock.release(true);
  }
  if (pool) await pool.end();
  await writeFile(reportPath, JSON.stringify(report, null, 2) + "\n").catch(() => {});
}
