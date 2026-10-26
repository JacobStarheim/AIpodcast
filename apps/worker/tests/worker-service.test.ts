import { afterEach, describe, expect, it, vi } from "vitest";
import { readFile } from "node:fs/promises";
import { PermanentError } from "../src/errors.js";
import type { TranscriptionResult, WorkerAiClient } from "../src/openai-client.js";
import type { ParsedFeed } from "../src/rss.js";
import type {
  ChapterToStore,
  ClaimedJob,
  EpisodeRecord,
  SegmentToStore,
  SourceRecord,
  WorkerStore
} from "../src/store.js";
import type { EpisodeSummaryResult, TimedText } from "../src/summarize.js";
import { WorkerService } from "../src/worker-service.js";

interface MemoryJob extends ClaimedJob {
  status: "queued" | "processing" | "completed" | "failed";
  error: string | null;
}

interface MemoryEpisode extends EpisodeRecord {
  guid: string;
  publishedAt: string;
  attempts: number;
  error: string | null;
  summary: string | null;
  summaryAttempts: number;
  segments: SegmentToStore[];
  chapters: ChapterToStore[];
}

const source: SourceRecord = { id: "source-1", name: "Test podcast", rssUrl: "https://podcast.test/feed.xml" };

/** In-memory WorkerStore with the same rules as the SQL in PostgresWorkerStore. */
class MemoryStore implements WorkerStore {
  jobs: MemoryJob[] = [];
  episodes: MemoryEpisode[] = [];
  feeds: ParsedFeed[] = [];

  queueJob(fields: Partial<ClaimedJob> = {}): string {
    const id = `job-${this.jobs.length + 1}`;
    this.jobs.push({
      id, sourceId: source.id, episodeId: null, maxEpisodesPerSource: 10,
      status: "queued", error: null, ...fields
    });
    return id;
  }

  job(id: string): MemoryJob {
    const job = this.jobs.find((item) => item.id === id);
    if (!job) throw new Error(`Missing job ${id}`);
    return job;
  }

  episode(guid: string): MemoryEpisode {
    const episode = this.episodes.find((item) => item.guid === guid);
    if (!episode) throw new Error(`Missing episode ${guid}`);
    return episode;
  }

  async requeueStaleJobs(): Promise<void> {}

  async claimNextJob(): Promise<ClaimedJob | null> {
    const job = this.jobs.find((item) => item.status === "queued");
    if (!job) return null;
    job.status = "processing";
    job.error = null;
    return { id: job.id, sourceId: job.sourceId, episodeId: job.episodeId, maxEpisodesPerSource: job.maxEpisodesPerSource };
  }

  async heartbeat(): Promise<void> {}

  async completeJob(jobId: string): Promise<void> {
    this.job(jobId).status = "completed";
  }

  async failJob(jobId: string, error: string): Promise<void> {
    Object.assign(this.job(jobId), { status: "failed", error });
  }

  async getActiveSources(sourceId: string | null): Promise<SourceRecord[]> {
    return sourceId === null || sourceId === source.id ? [source] : [];
  }

  async saveFeed(sourceId: string, feed: ParsedFeed): Promise<void> {
    this.feeds.push(feed);
    for (const item of feed.episodes) {
      const existing = this.episodes.find((episode) => episode.guid === item.guid);
      if (existing) {
        Object.assign(existing, { title: item.title, audioUrl: item.audioUrl, publishedAt: item.publishedAt });
        continue;
      }
      this.episodes.push({
        id: `episode-${this.episodes.length + 1}`, sourceId, guid: item.guid, title: item.title,
        audioUrl: item.audioUrl, publishedAt: item.publishedAt, status: "pending",
        durationSec: item.durationSec, attempts: 0, error: null, summary: null, summaryAttempts: 0,
        segments: [], chapters: []
      });
    }
  }

  async getEpisode(episodeId: string): Promise<EpisodeRecord | null> {
    return this.episodes.find((episode) => episode.id === episodeId) ?? null;
  }

  async selectEpisodesToTranscribe(sourceId: string, limit: number, maxAttempts: number): Promise<EpisodeRecord[]> {
    return this.episodes
      .filter((episode) => episode.sourceId === sourceId &&
        ["pending", "queued", "failed"].includes(episode.status) && episode.attempts < maxAttempts)
      .sort((a, b) => b.publishedAt.localeCompare(a.publishedAt))
      .slice(0, limit);
  }

  async startTranscription(episodeId: string): Promise<boolean> {
    const episode = this.episodes.find((item) => item.id === episodeId);
    if (!episode || !["pending", "queued", "failed"].includes(episode.status)) return false;
    Object.assign(episode, { status: "processing", attempts: episode.attempts + 1, error: null });
    return true;
  }

  async saveTranscript(episodeId: string, durationSec: number, segments: SegmentToStore[]): Promise<void> {
    const episode = this.episodes.find((item) => item.id === episodeId)!;
    Object.assign(episode, {
      status: "ready", error: null, segments, chapters: [], summary: null, summaryAttempts: 0,
      durationSec: episode.durationSec ?? Math.round(durationSec)
    });
  }

  async failTranscription(
    episodeId: string,
    error: string,
    options: { permanent: boolean; maxAttempts: number }
  ): Promise<void> {
    const episode = this.episodes.find((item) => item.id === episodeId)!;
    episode.status = "failed";
    episode.error = error;
    if (options.permanent) episode.attempts = Math.max(episode.attempts, options.maxAttempts);
  }

  async selectEpisodesMissingSummary(sourceId: string, limit: number, maxAttempts: number): Promise<EpisodeRecord[]> {
    return this.episodes
      .filter((episode) => episode.sourceId === sourceId && episode.status === "ready" &&
        episode.summary === null && episode.summaryAttempts < maxAttempts)
      .slice(0, limit);
  }

  async getTranscript(episodeId: string): Promise<TimedText[]> {
    return this.episodes.find((item) => item.id === episodeId)!.segments
      .map(({ startSec, endSec, text }) => ({ startSec, endSec, text }));
  }

  async saveSummary(
    episodeId: string,
    summary: { language: string | null; summary: string; chapters: ChapterToStore[] }
  ): Promise<void> {
    const episode = this.episodes.find((item) => item.id === episodeId)!;
    Object.assign(episode, {
      summary: summary.summary, chapters: summary.chapters, summaryAttempts: episode.summaryAttempts + 1
    });
  }

  async failSummary(episodeId: string): Promise<void> {
    this.episodes.find((item) => item.id === episodeId)!.summaryAttempts += 1;
  }
}

function validTranscription(): TranscriptionResult {
  return {
    durationSec: 20,
    segments: [{ start: 0, end: 20, text: "Podcast citations let listeners check an answer against the original audio." }]
  };
}

function validEmbedding(): number[] {
  return Array.from({ length: 1536 }, (_, index) => (index === 0 ? 1 : 0));
}

function validSummary(): EpisodeSummaryResult {
  return {
    language: "en",
    summary: "The episode explains citations.",
    chapters: [{ title: "Citations", summary: "Why citations matter.", startSec: 0, endSec: 20 }]
  };
}

function rssFor(guids: string[]): string {
  return `<rss version="2.0"><channel><title>Test podcast</title><language>en</language>${guids
    .map((guid, index) => `<item>
        <guid>${guid}</guid><title>${guid}</title><description>Test episode</description>
        <pubDate>${new Date(Date.UTC(2026, 0, 10 - index)).toUTCString()}</pubDate>
        <enclosure url="https://podcast.test/${guid}.mp3" type="audio/mpeg" />
      </item>`)
    .join("")}</channel></rss>`;
}

function setup(episodeGuids = ["episode-one"], options: { maxAttempts?: number; maxAudioBytes?: number } = {}) {
  const store = new MemoryStore();
  const audioFetches: string[] = [];
  const fetchImpl = vi.fn(async (url: string) => {
    if (url === source.rssUrl) {
      return new Response(rssFor(episodeGuids), { headers: { "content-type": "application/rss+xml" } });
    }
    if (episodeGuids.some((guid) => url === `https://podcast.test/${guid}.mp3`)) {
      audioFetches.push(url);
      return new Response("fake-audio", { headers: { "content-type": "audio/mpeg" } });
    }
    throw new Error(`Unexpected network request: ${url}`);
  });
  const ai = {
    transcribeEpisodeAudio: vi.fn<WorkerAiClient["transcribeEpisodeAudio"]>(async () => validTranscription()),
    embedTexts: vi.fn<WorkerAiClient["embedTexts"]>(async (texts) => texts.map(() => validEmbedding())),
    summarizeTranscript: vi.fn<WorkerAiClient["summarizeTranscript"]>(async () => validSummary())
  };
  const worker = new WorkerService(store, ai, {
    maxEpisodeAudioMb: options.maxAudioBytes === undefined ? 25 : options.maxAudioBytes / 1024 / 1024,
    defaultMaxEpisodesPerSource: 10,
    maxTranscriptionAttempts: options.maxAttempts ?? 3,
    // Test URLs resolve nowhere; the guard has its own tests.
    allowPrivateNetwork: true,
    fetchImpl: fetchImpl as unknown as typeof fetch
  });
  return { store, ai, worker, fetchImpl, audioFetches };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("WorkerService ingest outcomes", () => {
  it("marks the job failed when an episode fails, while still indexing the remaining episodes", async () => {
    const { store, ai, worker } = setup(["broken", "working"]);
    const jobId = store.queueJob();
    ai.transcribeEpisodeAudio.mockRejectedValueOnce(new Error("Transcription service unavailable"));

    await worker.pollOnce();

    expect(store.job(jobId).status).toBe("failed");
    expect(store.job(jobId).error).toContain("Transcription service unavailable");
    expect(store.episode("broken")).toMatchObject({ status: "failed", error: "Transcription service unavailable" });
    expect(store.episode("working").status).toBe("ready");
    expect(store.episode("working").segments).toEqual([
      expect.objectContaining({ startSec: 0, endSec: 20, text: validTranscription().segments[0]?.text })
    ]);
  });

  it("streams audio to a file and passes the path to transcription", async () => {
    const { store, ai, worker } = setup();
    store.queueJob();
    let downloaded = "";
    ai.transcribeEpisodeAudio.mockImplementationOnce(async ({ path, workDirectory }) => {
      expect(path.startsWith(workDirectory)).toBe(true);
      downloaded = await readFile(path, "utf8");
      return validTranscription();
    });
    await worker.pollOnce();
    expect(downloaded).toBe("fake-audio");
  });

  it("retries a failed episode in a new ingest job", async () => {
    const { store, ai, worker } = setup();
    const failedJobId = store.queueJob();
    ai.transcribeEpisodeAudio.mockRejectedValueOnce(new Error("Temporary upstream failure"));
    await worker.pollOnce();
    expect(store.episode("episode-one")).toMatchObject({ status: "failed", attempts: 1 });

    const retryJobId = store.queueJob();
    await worker.pollOnce();

    expect(store.job(failedJobId).status).toBe("failed");
    expect(store.job(retryJobId)).toMatchObject({ status: "completed", error: null });
    expect(store.episode("episode-one")).toMatchObject({ status: "ready", attempts: 2, error: null });
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(2);

    const alreadyReadyJobId = store.queueJob();
    await worker.pollOnce();
    expect(store.job(alreadyReadyJobId).status).toBe("completed");
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(2);
  });

  it("stops retrying after the attempt limit so older episodes get their turn", async () => {
    const { store, ai, worker } = setup(["newest", "older"], { maxAttempts: 2 });
    ai.transcribeEpisodeAudio.mockImplementation(async ({ path }) => {
      if ((await readFile(path, "utf8")) && store.episode("newest").status === "processing") {
        throw new Error("Upstream keeps failing");
      }
      return validTranscription();
    });

    for (let run = 0; run < 2; run += 1) {
      store.queueJob({ maxEpisodesPerSource: 1 });
      await worker.pollOnce();
    }
    expect(store.episode("newest")).toMatchObject({ status: "failed", attempts: 2 });
    expect(store.episode("older").status).toBe("pending");

    const jobId = store.queueJob({ maxEpisodesPerSource: 1 });
    await worker.pollOnce();
    expect(store.episode("older").status).toBe("ready");
    expect(store.episode("newest").attempts).toBe(2);
    expect(store.job(jobId).status).toBe("completed");
  });

  it("does not retry a permanent failure automatically", async () => {
    const { store, ai, worker } = setup(["too-big", "next"]);
    ai.transcribeEpisodeAudio.mockRejectedValueOnce(new PermanentError("Episode file contains no audio stream"));
    store.queueJob({ maxEpisodesPerSource: 1 });
    await worker.pollOnce();
    expect(store.episode("too-big")).toMatchObject({ status: "failed", attempts: 3 });

    store.queueJob({ maxEpisodesPerSource: 1 });
    await worker.pollOnce();
    expect(store.episode("next").status).toBe("ready");
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(2);
  });

  it("rejects audio above the size limit without transcribing it", async () => {
    const { store, ai, worker } = setup(["episode-one"], { maxAudioBytes: 4 });
    const jobId = store.queueJob();
    await worker.pollOnce();
    expect(store.episode("episode-one").status).toBe("failed");
    expect(store.episode("episode-one").error).toContain("limit");
    expect(store.episode("episode-one").attempts).toBe(3);
    expect(store.job(jobId).status).toBe("failed");
    expect(ai.transcribeEpisodeAudio).not.toHaveBeenCalled();
  });

  it("imports only the episode list when the job allows zero transcriptions", async () => {
    const { store, ai, worker } = setup(["one", "two"]);
    const jobId = store.queueJob({ maxEpisodesPerSource: 0 });
    await worker.pollOnce();
    expect(store.job(jobId).status).toBe("completed");
    expect(store.episodes.map((episode) => episode.status)).toEqual(["pending", "pending"]);
    expect(store.feeds[0]).toMatchObject({ title: "Test podcast", language: "en" });
    expect(ai.transcribeEpisodeAudio).not.toHaveBeenCalled();
  });

  it("transcribes a single requested episode even after earlier failures", async () => {
    const { store, ai, worker } = setup(["one", "two"], { maxAttempts: 1 });
    store.queueJob({ maxEpisodesPerSource: 0 });
    await worker.pollOnce();
    const target = store.episode("two");
    Object.assign(target, { status: "failed", attempts: 5 });

    const jobId = store.queueJob({ sourceId: null, episodeId: target.id });
    await worker.pollOnce();

    expect(store.job(jobId).status).toBe("completed");
    expect(store.episode("two")).toMatchObject({ status: "ready", attempts: 6 });
    expect(store.episode("one").status).toBe("pending");
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(1);
  });

  it("embeds each chunk with its neighbours but stores the chunk's own text", async () => {
    const { store, ai, worker } = setup();
    ai.transcribeEpisodeAudio.mockResolvedValueOnce({
      durationSec: 90,
      segments: [
        { start: 0, end: 30, text: "First passage about sensors." },
        { start: 30, end: 60, text: "Second passage about the ship." },
        { start: 60, end: 90, text: "Third passage about the port." }
      ]
    });
    store.queueJob();
    await worker.pollOnce();

    expect(ai.embedTexts.mock.calls[0]?.[0]).toEqual([
      "First passage about sensors.\nSecond passage about the ship.",
      "First passage about sensors.\nSecond passage about the ship.\nThird passage about the port.",
      "Second passage about the ship.\nThird passage about the port."
    ]);
    expect(store.episode("episode-one").segments.map((segment) => segment.text)).toEqual([
      "First passage about sensors.",
      "Second passage about the ship.",
      "Third passage about the port."
    ]);
  });

  it("stores a summary and chapters after transcription", async () => {
    const { store, ai, worker } = setup();
    store.queueJob();
    await worker.pollOnce();
    expect(ai.summarizeTranscript).toHaveBeenCalledWith(expect.objectContaining({
      title: "episode-one",
      durationSec: 20,
      segments: [expect.objectContaining({ startSec: 0, endSec: 20 })]
    }));
    expect(store.episode("episode-one")).toMatchObject({
      summary: "The episode explains citations.",
      chapters: [expect.objectContaining({ title: "Citations", embedding: validEmbedding() })]
    });
  });

  it("keeps an episode ready when only the summary fails, and backfills it later", async () => {
    const { store, ai, worker } = setup();
    ai.summarizeTranscript.mockRejectedValueOnce(new Error("Summary service down"));
    vi.spyOn(console, "error").mockImplementation(() => {});
    const jobId = store.queueJob();
    await worker.pollOnce();
    expect(store.job(jobId).status).toBe("completed");
    expect(store.episode("episode-one")).toMatchObject({ status: "ready", summary: null, summaryAttempts: 1 });

    store.queueJob({ maxEpisodesPerSource: 0 });
    await worker.pollOnce();
    expect(store.episode("episode-one").summary).toBe("The episode explains citations.");
    expect(ai.transcribeEpisodeAudio).toHaveBeenCalledTimes(1);
  });

  it.each([
    { name: "no segments", segments: [] },
    { name: "only blank text", segments: [{ start: 0, end: 10, text: " \n\t " }] }
  ])("never marks a transcription with $name ready", async ({ segments }) => {
    const { store, ai, worker } = setup();
    const jobId = store.queueJob();
    ai.transcribeEpisodeAudio.mockResolvedValueOnce({ durationSec: 10, segments });

    await worker.pollOnce();

    expect(store.episode("episode-one").status).toBe("failed");
    expect(store.job(jobId).status).toBe("failed");
    expect(store.episode("episode-one").segments).toHaveLength(0);
    expect(ai.embedTexts).not.toHaveBeenCalled();
  });

  it.each([
    { name: "empty", embedding: [] },
    { name: "too short", embedding: Array<number>(1535).fill(0) },
    { name: "too long", embedding: Array<number>(1537).fill(0) },
    { name: "NaN", embedding: validEmbedding().map((value, index) => (index === 5 ? Number.NaN : value)) },
    { name: "infinite", embedding: validEmbedding().map((value, index) => (index === 5 ? Number.POSITIVE_INFINITY : value)) }
  ])("rejects an $name embedding in a later chunk without storing a partial transcript", async ({ embedding }) => {
    const { store, ai, worker } = setup();
    const jobId = store.queueJob();
    ai.transcribeEpisodeAudio.mockResolvedValueOnce({
      durationSec: 160,
      segments: [
        { start: 0, end: 10, text: "The first chunk has a valid embedding." },
        { start: 150, end: 160, text: "The later chunk has an invalid embedding." }
      ]
    });
    ai.embedTexts.mockResolvedValueOnce([validEmbedding(), embedding]);

    await worker.pollOnce();

    expect(store.episode("episode-one").status).toBe("failed");
    expect(store.job(jobId).status).toBe("failed");
    expect(store.episode("episode-one").segments).toHaveLength(0);
  });

  it("fails the job with a clear message when the feed is unreachable", async () => {
    const { store, worker, fetchImpl } = setup();
    fetchImpl.mockImplementationOnce(async () => new Response("gone", { status: 404 }));
    const jobId = store.queueJob();
    await worker.pollOnce();
    expect(store.job(jobId)).toMatchObject({ status: "failed" });
    expect(store.job(jobId).error).toContain("HTTP 404");
  });
});
