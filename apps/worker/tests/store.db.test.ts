import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { assertSchemaVersion } from "../src/db.js";
import type { WorkerAiClient } from "../src/openai-client.js";
import { PostgresWorkerStore } from "../src/store.js";
import { WorkerService } from "../src/worker-service.js";

// Runs against a real, migrated database: `npm run test:db` from the repository root.
const databaseUrl = process.env.TEST_DATABASE_URL;

function embedding(seed: number): number[] {
  return Array.from({ length: 1536 }, (_, index) => (index === seed ? 1 : 0));
}

const rss = (guids: string[]) => `<rss><channel><title>DB podcast</title><language>en</language>
  <itunes:image xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" href="https://cdn.test/show.jpg"/>
  ${guids.map((guid, index) => `<item><guid>${guid}</guid><title>${guid}</title>
    <pubDate>${new Date(Date.UTC(2026, 0, 20 - index)).toUTCString()}</pubDate>
    <enclosure url="https://cdn.test/${guid}.mp3" type="audio/mpeg"/><itunes:duration>1:05.4</itunes:duration>
  </item>`).join("")}</channel></rss>`;

describe.runIf(databaseUrl)("PostgresWorkerStore against PostgreSQL", () => {
  let pool: pg.Pool;
  let store: PostgresWorkerStore;

  beforeAll(async () => {
    pool = new pg.Pool({ connectionString: databaseUrl, max: 4 });
    store = new PostgresWorkerStore(pool);
    await assertSchemaVersion(pool);
  });

  afterAll(async () => {
    await pool.end();
  });

  beforeEach(async () => {
    await pool.query("TRUNCATE rss_sources, episodes, transcript_segments, episode_chapters, ingest_jobs, qa_events CASCADE");
  });

  async function createSource(name = ""): Promise<string> {
    const result = await pool.query(
      "INSERT INTO rss_sources (name, rss_url) VALUES ($1, 'https://feeds.test/rss') RETURNING id",
      [name]
    );
    return String(result.rows[0].id);
  }

  async function queueJob(sourceId: string | null, max: number | null, episodeId: string | null = null) {
    const result = await pool.query(
      "INSERT INTO ingest_jobs (source_id, max_episodes_per_source, episode_id) VALUES ($1, $2, $3) RETURNING id",
      [sourceId, max, episodeId]
    );
    return String(result.rows[0].id);
  }

  function worker(ai: WorkerAiClient, guids: string[], maxAttempts = 3) {
    const fetchImpl = vi.fn(async (url: string) => url === "https://feeds.test/rss"
      ? new Response(rss(guids))
      : new Response("audio-bytes", { headers: { "content-type": "audio/mpeg" } }));
    return new WorkerService(store, ai, {
      maxEpisodeAudioMb: 1,
      defaultMaxEpisodesPerSource: 10,
      maxTranscriptionAttempts: maxAttempts,
      allowPrivateNetwork: true,
      fetchImpl: fetchImpl as unknown as typeof fetch
    });
  }

  function fakeAi(): WorkerAiClient {
    return {
      transcribeEpisodeAudio: vi.fn(async () => ({
        durationSec: 45,
        segments: [
          { start: 0, end: 20, text: "Aurora carries twenty four sensors." },
          { start: 20, end: 45, text: "The ship leaves Tromso on Tuesday." }
        ]
      })),
      embedTexts: vi.fn(async (texts: string[]) => texts.map((_, index) => embedding(index))),
      summarizeTranscript: vi.fn(async () => ({
        language: "en",
        summary: "A short research voyage.",
        chapters: [
          { title: "Sensors", summary: "The sensors.", startSec: 0, endSec: 20 },
          { title: "Departure", summary: "Leaving port.", startSec: 20, endSec: 45 }
        ]
      }))
    };
  }

  it("imports a feed, transcribes, indexes and summarizes through real SQL", async () => {
    const sourceId = await createSource();
    const jobId = await queueJob(sourceId, 1);
    await worker(fakeAi(), ["newest", "older"]).pollOnce();

    const job = await pool.query("SELECT status, error FROM ingest_jobs WHERE id = $1", [jobId]);
    expect(job.rows[0]).toEqual({ status: "completed", error: null });

    const source = await pool.query("SELECT name, image_url, language FROM rss_sources WHERE id = $1", [sourceId]);
    expect(source.rows[0]).toEqual({ name: "DB podcast", image_url: "https://cdn.test/show.jpg", language: "en" });

    const episodes = await pool.query(
      `SELECT guid, transcription_status, transcription_attempts, duration_sec, summary, language
       FROM episodes ORDER BY published_at DESC`
    );
    expect(episodes.rows).toEqual([
      { guid: "newest", transcription_status: "ready", transcription_attempts: 1, duration_sec: 65,
        summary: "A short research voyage.", language: "en" },
      { guid: "older", transcription_status: "pending", transcription_attempts: 0, duration_sec: 65,
        summary: null, language: null }
    ]);

    const segments = await pool.query(
      "SELECT start_sec, end_sec, text, context_text, search_tsv IS NOT NULL AS indexed FROM transcript_segments ORDER BY start_sec"
    );
    expect(segments.rows).toEqual([
      { start_sec: 0, end_sec: 20, text: "Aurora carries twenty four sensors.",
        context_text: "Aurora carries twenty four sensors.\nThe ship leaves Tromso on Tuesday.", indexed: true },
      { start_sec: 20, end_sec: 45, text: "The ship leaves Tromso on Tuesday.",
        context_text: "Aurora carries twenty four sensors.\nThe ship leaves Tromso on Tuesday.", indexed: true }
    ]);

    const chapters = await pool.query("SELECT position, title, start_sec, end_sec FROM episode_chapters ORDER BY position");
    expect(chapters.rows).toEqual([
      { position: 0, title: "Sensors", start_sec: 0, end_sec: 20 },
      { position: 1, title: "Departure", start_sec: 20, end_sec: 45 }
    ]);

    // The HNSW index serves cosine queries filtered to one episode.
    const nearest = await pool.query(
      `SELECT text FROM transcript_segments ORDER BY embedding <=> $1::vector LIMIT 1`,
      [`[${embedding(1).join(",")}]`]
    );
    expect(nearest.rows[0].text).toBe("The ship leaves Tromso on Tuesday.");
  });

  it("re-importing a feed keeps statuses and does not duplicate episodes", async () => {
    const sourceId = await createSource("Named by user");
    await queueJob(sourceId, 1);
    const ai = fakeAi();
    await worker(ai, ["newest", "older"]).pollOnce();
    await queueJob(sourceId, 0);
    await worker(ai, ["brand-new", "newest", "older"]).pollOnce();

    const episodes = await pool.query("SELECT guid, transcription_status FROM episodes ORDER BY published_at DESC");
    expect(episodes.rows.map((row) => `${row.guid}:${row.transcription_status}`))
      .toEqual(["brand-new:pending", "newest:ready", "older:pending"]);
    const source = await pool.query("SELECT name FROM rss_sources WHERE id = $1", [sourceId]);
    expect(source.rows[0].name).toBe("Named by user");
  });

  it("records failures without touching the description and stops after the attempt limit", async () => {
    const sourceId = await createSource();
    const ai = fakeAi();
    vi.mocked(ai.transcribeEpisodeAudio).mockRejectedValue(new Error("Upstream down"));
    for (let run = 0; run < 3; run += 1) {
      await queueJob(sourceId, 1);
      await worker(ai, ["only"], 2).pollOnce();
    }
    const episode = await pool.query(
      "SELECT description, transcription_status, transcription_attempts, transcription_error FROM episodes"
    );
    expect(episode.rows[0]).toEqual({
      description: "", transcription_status: "failed", transcription_attempts: 2,
      transcription_error: "Upstream down"
    });
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(2);
  });

  it("claims each job once and requeues jobs from a stopped worker", async () => {
    const sourceId = await createSource();
    const jobId = await queueJob(sourceId, 0);
    const [first, second] = await Promise.all([store.claimNextJob(), store.claimNextJob()]);
    expect([first?.id, second?.id].filter(Boolean)).toEqual([jobId]);

    await pool.query("UPDATE ingest_jobs SET heartbeat_at = NOW() - INTERVAL '20 minutes' WHERE id = $1", [jobId]);
    await store.requeueStaleJobs(600);
    const job = await pool.query("SELECT status, error FROM ingest_jobs WHERE id = $1", [jobId]);
    expect(job.rows[0].status).toBe("queued");
    expect(job.rows[0].error).toContain("stopped responding");

    await store.claimNextJob();
    await store.heartbeat(jobId, null);
    await store.requeueStaleJobs(600);
    const fresh = await pool.query("SELECT status FROM ingest_jobs WHERE id = $1", [jobId]);
    expect(fresh.rows[0].status).toBe("processing");
  });

  it("runs a single-episode job", async () => {
    const sourceId = await createSource();
    await queueJob(sourceId, 0);
    const ai = fakeAi();
    await worker(ai, ["a", "b"]).pollOnce();
    const target = await pool.query("SELECT id FROM episodes WHERE guid = 'b'");
    await pool.query("UPDATE episodes SET transcription_status = 'queued' WHERE guid = 'b'");
    const jobId = await queueJob(null, null, String(target.rows[0].id));
    await worker(ai, ["a", "b"]).pollOnce();

    const statuses = await pool.query("SELECT guid, transcription_status FROM episodes ORDER BY guid");
    expect(statuses.rows).toEqual([
      { guid: "a", transcription_status: "pending" },
      { guid: "b", transcription_status: "ready" }
    ]);
    const job = await pool.query("SELECT status FROM ingest_jobs WHERE id = $1", [jobId]);
    expect(job.rows[0].status).toBe("completed");
  });
});
