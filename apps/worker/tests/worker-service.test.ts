import type { Pool } from "pg";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { TranscriptionResult } from "../src/openai-client.js";
import { WorkerService } from "../src/worker-service.js";

interface StoredJob {
  id: string;
  source_id: string;
  max_episodes_per_source: number;
  status: "queued" | "processing" | "completed" | "failed";
  error: string | null;
}

interface StoredEpisode {
  id: string;
  source_id: string;
  guid: string;
  title: string;
  description: string;
  published_at: string;
  audio_url: string;
  duration_sec: number | null;
  transcription_status: "pending" | "ready" | "failed";
}

interface StoredSegment {
  episode_id: string;
  start_sec: number;
  end_sec: number;
  speaker: string | null;
  text: string;
  embedding: string | null;
}

interface StoredState {
  jobs: StoredJob[];
  episodes: StoredEpisode[];
  segments: StoredSegment[];
}

const source = {
  id: "source-1",
  name: "Test podcast",
  rss_url: "https://podcast.test/feed.xml"
};

// Exercise the public polling flow with persistent state and real rollback
// semantics. Unsupported SQL fails the test instead of silently returning rows.
class MemoryPool {
  state: StoredState = { jobs: [], episodes: [], segments: [] };
  unexpectedQueries: string[] = [];

  queueJob(): string {
    const id = `job-${this.state.jobs.length + 1}`;
    this.state.jobs.push({
      id,
      source_id: source.id,
      max_episodes_per_source: 10,
      status: "queued",
      error: null
    });
    return id;
  }

  job(id: string): StoredJob {
    const job = this.state.jobs.find((item) => item.id === id);
    if (!job) throw new Error(`Missing job ${id}`);
    return job;
  }

  episode(guid: string): StoredEpisode {
    const episode = this.state.episodes.find((item) => item.guid === guid);
    if (!episode) throw new Error(`Missing episode ${guid}`);
    return episode;
  }

  async query(sql: string, values: unknown[] = []) {
    return this.execute(sql, values, this.state);
  }

  async connect() {
    let transaction: StoredState | null = null;
    return {
      query: async (sql: string, values: unknown[] = []) => {
        switch (sql.trim().toUpperCase()) {
          case "BEGIN":
            transaction = structuredClone(this.state);
            return { rows: [], rowCount: 0 };
          case "COMMIT":
            if (!transaction) throw new Error("No transaction to commit");
            this.state = transaction;
            transaction = null;
            return { rows: [], rowCount: 0 };
          case "ROLLBACK":
            transaction = null;
            return { rows: [], rowCount: 0 };
          default:
            return this.execute(sql, values, transaction ?? this.state);
        }
      },
      release: () => {}
    };
  }

  private execute(sql: string, values: unknown[], state: StoredState) {
    const statement = sql.trim().replace(/\s+/g, " ").toLowerCase();
    const result = (rows: unknown[] = []) => ({ rows, rowCount: rows.length });

    if (statement.startsWith("select") && statement.includes("from ingest_jobs")) {
      return result(state.jobs.filter((job) => job.status === "queued").slice(0, 5).map((job) => ({ ...job })));
    }

    if (statement.startsWith("update ingest_jobs")) {
      const job = state.jobs.find((item) => item.id === values[0]);
      if (!job || (statement.includes("and status = 'queued'") && job.status !== "queued")) {
        return result();
      }
      const status = statement.match(/set status = '(processing|completed|failed)'/)?.[1];
      if (!status) return this.unsupported(sql);
      job.status = status as StoredJob["status"];
      if (status === "processing") job.error = null;
      if (status === "failed") job.error = String(values[1]);
      return result([{ ...job }]);
    }

    if (statement.startsWith("select") && statement.includes("from rss_sources")) {
      return result(values.length === 0 || values[0] === source.id ? [{ ...source }] : []);
    }

    if (statement.startsWith("insert into episodes")) {
      const existing = state.episodes.find((episode) => episode.source_id === values[0] && episode.guid === values[1]);
      const fields = {
        source_id: String(values[0]),
        guid: String(values[1]),
        title: String(values[2]),
        description: String(values[3]),
        published_at: String(values[4]),
        audio_url: String(values[5]),
        duration_sec: values[6] === null ? null : Number(values[6])
      };
      if (existing) {
        Object.assign(existing, fields);
      } else {
        state.episodes.push({
          id: `episode-${state.episodes.length + 1}`,
          ...fields,
          transcription_status: "pending"
        });
      }
      return result();
    }

    if (statement.startsWith("select") && statement.includes("from episodes")) {
      const statusClause = statement.match(/transcription_status\s*(?:=\s*('[^']+')|in\s*\(([^)]+)\))/);
      if (!statusClause) return this.unsupported(sql);
      const statuses = [...(statusClause[1] ?? statusClause[2] ?? "").matchAll(/'([^']+)'/g)].map((match) => match[1]);
      return result(
        state.episodes
          .filter((episode) => episode.source_id === values[0] && statuses.includes(episode.transcription_status))
          .sort((a, b) => b.published_at.localeCompare(a.published_at))
          .slice(0, Number(values[1]))
          .map((episode) => ({ ...episode }))
      );
    }

    if (statement.startsWith("update episodes")) {
      const episode = state.episodes.find((item) => item.id === values[0]);
      if (!episode) return result();
      const status = statement.match(/set transcription_status = '(ready|failed)'/)?.[1];
      if (!status) return this.unsupported(sql);
      episode.transcription_status = status as StoredEpisode["transcription_status"];
      if (status === "ready") episode.duration_sec ??= Number(values[1]);
      if (status === "failed") episode.description += `\n\n[Transcription failed: ${values[1]}]`;
      return result([{ ...episode }]);
    }

    if (statement.startsWith("delete from transcript_segments")) {
      state.segments = state.segments.filter((segment) => segment.episode_id !== values[0]);
      return result();
    }

    if (statement.startsWith("insert into transcript_segments")) {
      state.segments.push({
        episode_id: String(values[0]),
        start_sec: Number(values[1]),
        end_sec: Number(values[2]),
        speaker: values[3] === null ? null : String(values[3]),
        text: String(values[4]),
        embedding: values[5] === null ? null : String(values[5])
      });
      return result();
    }

    return this.unsupported(sql);
  }

  private unsupported(sql: string): never {
    this.unexpectedQueries.push(sql);
    throw new Error(`Unsupported test SQL: ${sql}`);
  }
}

const pools: MemoryPool[] = [];

afterEach(() => {
  vi.unstubAllGlobals();
  for (const pool of pools.splice(0)) {
    expect(pool.unexpectedQueries).toEqual([]);
  }
});

function validTranscription(): TranscriptionResult {
  return {
    durationSec: 20,
    segments: [{ start: 0, end: 20, text: "Podcast citations let listeners check an answer against the original audio." }]
  };
}

function validEmbedding(): number[] {
  return Array.from({ length: 1536 }, (_, index) => (index === 0 ? 1 : 0));
}

function setup(episodeGuids = ["episode-one"]) {
  const pool = new MemoryPool();
  pools.push(pool);
  const rss = `<rss version="2.0"><channel><title>Test podcast</title>${episodeGuids
    .map(
      (guid, index) => `<item>
        <guid>${guid}</guid><title>${guid}</title><description>Test episode</description>
        <pubDate>${new Date(Date.UTC(2026, 0, 10 - index)).toUTCString()}</pubDate>
        <enclosure url="https://podcast.test/${guid}.mp3" type="audio/mpeg" />
      </item>`
    )
    .join("")}</channel></rss>`;
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string) => {
      if (url === source.rss_url) return new Response(rss, { headers: { "content-type": "application/rss+xml" } });
      if (episodeGuids.some((guid) => url === `https://podcast.test/${guid}.mp3`)) {
        return new Response("fake-audio", { headers: { "content-type": "audio/mpeg" } });
      }
      throw new Error(`Unexpected network request: ${url}`);
    })
  );
  const ai = {
    transcribeEpisodeAudio: vi.fn(async (_input: { buffer: Buffer; filename: string; mimeType: string }) => validTranscription()),
    embedText: vi.fn(async (_text: string) => validEmbedding())
  };
  const worker = new WorkerService(pool as unknown as Pool, ai, {
    maxEpisodeAudioMb: 25,
    defaultMaxEpisodesPerSource: 10
  });
  return { pool, ai, worker };
}

describe("WorkerService ingest outcomes", () => {
  it("marks the job failed when an episode fails, while still indexing the remaining episodes", async () => {
    const { pool, ai, worker } = setup(["broken", "working"]);
    const jobId = pool.queueJob();
    ai.transcribeEpisodeAudio.mockRejectedValueOnce(new Error("Transcription service unavailable"));

    await worker.pollOnce();

    expect(pool.job(jobId).status).toBe("failed");
    expect(pool.job(jobId).error).toContain("Transcription service unavailable");
    expect(pool.episode("broken").transcription_status).toBe("failed");
    expect(pool.episode("working").transcription_status).toBe("ready");
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(2);
    expect(pool.state.segments).toEqual([
      expect.objectContaining({
        episode_id: pool.episode("working").id,
        start_sec: 0,
        end_sec: 20,
        text: validTranscription().segments[0]?.text
      })
    ]);
  });

  it("retries a failed episode in a new ingest job and preserves the earlier failure record", async () => {
    const { pool, ai, worker } = setup();
    const failedJobId = pool.queueJob();
    ai.transcribeEpisodeAudio.mockRejectedValueOnce(new Error("Temporary upstream failure"));
    await worker.pollOnce();
    const episodeId = pool.episode("episode-one").id;
    expect(pool.episode("episode-one").transcription_status).toBe("failed");
    expect(pool.state.segments).toHaveLength(0);

    const retryJobId = pool.queueJob();
    await worker.pollOnce();

    expect(pool.job(failedJobId).status).toBe("failed");
    expect(pool.job(retryJobId)).toMatchObject({ status: "completed", error: null });
    expect(pool.state.episodes).toHaveLength(1);
    expect(pool.episode("episode-one")).toMatchObject({ id: episodeId, transcription_status: "ready" });
    expect(pool.state.segments).toHaveLength(1);
    expect(pool.state.segments[0]).toMatchObject({ episode_id: episodeId, embedding: `[${validEmbedding().join(",")}]` });
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(2);

    const alreadyReadyJobId = pool.queueJob();
    await worker.pollOnce();
    expect(pool.job(alreadyReadyJobId).status).toBe("completed");
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(2);
    expect(pool.state.segments).toHaveLength(1);
  });

  it.each([
    { name: "no segments", segments: [] },
    { name: "only blank text", segments: [{ start: 0, end: 10, text: " \n\t " }] }
  ])("never marks a transcription with $name ready", async ({ segments }) => {
    const { pool, ai, worker } = setup();
    const jobId = pool.queueJob();
    ai.transcribeEpisodeAudio.mockResolvedValueOnce({ durationSec: 10, segments });

    await worker.pollOnce();

    expect(pool.episode("episode-one").transcription_status).toBe("failed");
    expect(pool.job(jobId).status).toBe("failed");
    expect(pool.job(jobId).error).toEqual(expect.any(String));
    expect(pool.state.segments).toHaveLength(0);
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(1);
    expect(ai.embedText).not.toHaveBeenCalled();
  });

  it.each([
    { name: "empty", embedding: [] },
    { name: "too short", embedding: Array<number>(1535).fill(0) },
    { name: "too long", embedding: Array<number>(1537).fill(0) },
    { name: "NaN", embedding: validEmbedding().map((value, index) => (index === 5 ? Number.NaN : value)) },
    { name: "infinite", embedding: validEmbedding().map((value, index) => (index === 5 ? Number.POSITIVE_INFINITY : value)) }
  ])("rejects an $name embedding in a later chunk without leaving a partial transcript", async ({ embedding }) => {
    const { pool, ai, worker } = setup();
    const jobId = pool.queueJob();
    ai.transcribeEpisodeAudio.mockResolvedValueOnce({
      durationSec: 160,
      segments: [
        { start: 0, end: 10, text: "The first chunk has a valid embedding." },
        { start: 150, end: 160, text: "The later chunk has an invalid embedding." }
      ]
    });
    ai.embedText.mockResolvedValueOnce(validEmbedding()).mockResolvedValueOnce(embedding);

    await worker.pollOnce();

    expect(ai.embedText).toHaveBeenCalledTimes(2);
    expect(pool.episode("episode-one").transcription_status).toBe("failed");
    expect(pool.job(jobId).status).toBe("failed");
    expect(pool.state.segments).toHaveLength(0);
  });
});
