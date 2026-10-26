import { copyFile, mkdir, mkdtemp, rename, rm, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { transcriptionPrompt } from "@podcast/shared-types";
import { buildContextTexts, chunkTranscriptSegments } from "./chunking.js";
import { downloadToFile } from "./download.js";
import { PermanentError } from "./errors.js";
import { guardedFetch } from "./network-guard.js";
import type { WorkerAiClient } from "./openai-client.js";
import { parseFeed } from "./rss.js";
import type { ClaimedJob, EpisodeRecord, SourceRecord, StoredAudio, WorkerStore } from "./store.js";

export interface WorkerServiceOptions {
  maxEpisodeAudioMb: number;
  defaultMaxEpisodesPerSource: number;
  maxTranscriptionAttempts: number;
  allowPrivateNetwork: boolean;
  /** Longest clip the transcript chunks may merge into, in seconds. */
  maxChunkSec?: number;
  staleJobSec?: number;
  heartbeatMs?: number;
  tempDirectory?: string;
  /** Where transcribed audio is kept for playback; unset keeps nothing. */
  audioStorageDirectory?: string;
  /** Refresh every feed this often; unset disables periodic refresh. */
  feedRefreshSec?: number;
  /** Audio seconds that may be sent for transcription per UTC day. */
  dailyTranscriptionSec?: number;
  fetchImpl?: typeof fetch;
}

const MAX_SUMMARY_ATTEMPTS = 2;
const SUMMARY_BACKFILL_PER_JOB = 5;
const AUTO_TRANSCRIBE_PER_REFRESH = 5;
/** Assumed length of an episode whose feed gives no duration. */
const UNKNOWN_DURATION_SEC = 3600;
export const BUDGET_EXCEEDED_MESSAGE = "Today's transcription limit is used up; request it again tomorrow";

const AUDIO_EXTENSIONS: Record<string, string> = {
  "audio/mpeg": ".mp3", "audio/mp3": ".mp3", "audio/mp4": ".m4a", "audio/x-m4a": ".m4a", "audio/m4a": ".m4a",
  "audio/aac": ".aac", "audio/ogg": ".ogg", "audio/opus": ".opus", "audio/wav": ".wav", "audio/x-wav": ".wav",
  "audio/webm": ".webm", "audio/flac": ".flac"
};

/** rename(), falling back to copy and delete across file systems. */
async function moveFile(from: string, to: string): Promise<void> {
  try {
    await rename(from, to);
  } catch (error) {
    if (!(error && typeof error === "object" && "code" in error && error.code === "EXDEV")) throw error;
    await copyFile(from, to);
    await unlink(from);
  }
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : "unknown_error";
}

export class WorkerService {
  private currentEpisodeId: string | null = null;

  constructor(
    private readonly store: WorkerStore,
    private readonly aiClient: WorkerAiClient,
    private readonly options: WorkerServiceOptions
  ) {}

  async pollOnce(maxJobs = 5): Promise<void> {
    await this.store.requeueStaleJobs(this.options.staleJobSec ?? 600);
    if (this.options.feedRefreshSec) {
      await this.store.enqueueDueRefreshes(this.options.feedRefreshSec);
    }
    for (let processed = 0; processed < maxJobs; processed += 1) {
      const job = await this.store.claimNextJob();
      if (!job) return;
      await this.processJob(job);
    }
  }

  private async processJob(job: ClaimedJob): Promise<void> {
    const heartbeat = setInterval(() => {
      this.store.heartbeat(job.id, this.currentEpisodeId).catch(() => {});
    }, this.options.heartbeatMs ?? 30_000);
    try {
      const failures = job.episodeId
        ? await this.processEpisodeJob(job.episodeId)
        : await this.processSourceJob(job);
      if (failures.length > 0) {
        await this.store.failJob(job.id, failures.join("; "));
      } else {
        await this.store.completeJob(job.id);
      }
    } catch (error) {
      await this.store.failJob(job.id, messageOf(error));
    } finally {
      clearInterval(heartbeat);
      this.currentEpisodeId = null;
    }
  }

  /** A user asked for this episode, so it runs even after earlier failed attempts. */
  private async processEpisodeJob(episodeId: string): Promise<string[]> {
    const episode = await this.store.getEpisode(episodeId);
    if (!episode) throw new Error("Episode no longer exists");
    if (episode.status === "ready" || episode.status === "processing") return [];
    try {
      await this.transcribeEpisode(episode, { requested: true });
      return [];
    } catch (error) {
      return [`${episode.title}: ${messageOf(error)}`];
    }
  }

  private async processSourceJob(job: ClaimedJob): Promise<string[]> {
    const sources = await this.store.getActiveSources(job.sourceId);
    if (sources.length === 0) {
      throw new Error("No active RSS sources found for this ingest job");
    }
    const failures: string[] = [];
    for (const source of sources) {
      const limit = job.maxEpisodesPerSource ?? this.options.defaultMaxEpisodesPerSource;
      try {
        failures.push(...(await this.processSource(source, limit)));
      } catch (error) {
        failures.push(`${source.name || source.rssUrl}: ${messageOf(error)}`);
      }
    }
    return failures;
  }

  private async processSource(source: SourceRecord, maxEpisodes: number): Promise<string[]> {
    const response = await guardedFetch(
      source.rssUrl,
      { signal: AbortSignal.timeout(30_000), headers: { Accept: "application/rss+xml, application/xml, text/xml" } },
      { allowPrivateNetwork: this.options.allowPrivateNetwork, fetchImpl: this.options.fetchImpl }
    );
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`Failed to fetch RSS feed: HTTP ${response.status}`);
    }
    const feed = parseFeed(await response.text());
    if (feed.episodes.length === 0) {
      throw new Error("The feed contains no episodes with audio");
    }
    await this.store.saveFeed(source.id, feed);

    // Episodes indexed before summaries existed, or whose summary failed once.
    // Done first so episodes transcribed below are not summarized twice.
    const missing = await this.store.selectEpisodesMissingSummary(
      source.id,
      SUMMARY_BACKFILL_PER_JOB,
      MAX_SUMMARY_ATTEMPTS
    );
    for (const episode of missing) {
      await this.summarizeEpisode(episode);
    }

    const failures: string[] = [];
    const episodes = await this.store.selectEpisodesToTranscribe(
      source.id,
      maxEpisodes,
      this.options.maxTranscriptionAttempts
    );
    if (source.autoTranscribe) {
      episodes.push(...(await this.store.selectAutoTranscribeEpisodes(
        source.id,
        AUTO_TRANSCRIBE_PER_REFRESH,
        this.options.maxTranscriptionAttempts
      )).filter((candidate) => !episodes.some((episode) => episode.id === candidate.id)));
    }
    for (const episode of episodes) {
      try {
        await this.transcribeEpisode(episode, { requested: false });
      } catch (error) {
        failures.push(`${episode.title}: ${messageOf(error)}`);
      }
    }
    return failures;
  }

  /**
   * Checks the daily limit with the feed's duration (or an hour when unknown).
   * Episodes a user asked for fail with a clear message; automatic ones wait
   * for a later refresh.
   */
  private async withinBudget(episode: EpisodeRecord, requested: boolean): Promise<boolean> {
    const dailySec = this.options.dailyTranscriptionSec;
    if (!dailySec) return true;
    const remaining = dailySec - (await this.store.getTranscribedSecondsToday());
    if ((episode.durationSec ?? UNKNOWN_DURATION_SEC) <= remaining) return true;
    if (requested) {
      await this.store.failTranscription(episode.id, BUDGET_EXCEEDED_MESSAGE, {
        permanent: false,
        maxAttempts: this.options.maxTranscriptionAttempts
      });
    }
    return false;
  }

  private async transcribeEpisode(episode: EpisodeRecord, { requested }: { requested: boolean }): Promise<void> {
    if (!(await this.withinBudget(episode, requested))) return;
    if (!(await this.store.startTranscription(episode.id))) return;
    this.currentEpisodeId = episode.id;
    const workDirectory = await mkdtemp(join(this.options.tempDirectory ?? tmpdir(), "podcast-episode-"));
    let durationSec: number;
    try {
      const audioPath = join(workDirectory, "episode.audio");
      const download = await downloadToFile(episode.audioUrl, audioPath, {
        maxBytes: this.options.maxEpisodeAudioMb * 1024 * 1024,
        allowPrivateNetwork: this.options.allowPrivateNetwork,
        fetchImpl: this.options.fetchImpl
      });
      const transcription = await this.aiClient.transcribeEpisodeAudio({
        path: audioPath,
        workDirectory,
        prompt: transcriptionPrompt({ show: episode.sourceName, title: episode.title, text: episode.description })
      });
      durationSec = transcription.durationSec;
      await this.store.addTranscribedSeconds(durationSec);

      if (!Number.isFinite(durationSec) || durationSec <= 0 ||
          transcription.segments.some((segment) =>
            !Number.isFinite(segment.start) || !Number.isFinite(segment.end) ||
            segment.start < 0 || segment.end <= segment.start ||
            segment.end > durationSec + 0.1)) {
        throw new Error("Transcription returned invalid timestamps");
      }
      // Keep clip-sized citation windows instead of merging into long passages.
      const chunks = chunkTranscriptSegments(transcription.segments, {
        maxDurationSec: this.options.maxChunkSec ?? 30
      });
      if (chunks.length === 0) {
        throw new Error("Transcription returned no speech");
      }

      const contextTexts = buildContextTexts(chunks);
      const embeddings = await this.aiClient.embedTexts(contextTexts);
      if (embeddings.length !== chunks.length || embeddings.some((embedding) =>
        embedding.length !== 1536 || embedding.some((value) => !Number.isFinite(value)))) {
        throw new Error("Embedding must contain 1536 finite values");
      }
      const previousAudio = await this.store.getStoredAudioFile(episode.id);
      const audio = await this.keepAudio(episode.id, audioPath, download);
      try {
        await this.store.saveTranscript(
          episode.id,
          durationSec,
          chunks.map((chunk, index) => ({
            ...chunk,
            contextText: contextTexts[index] ?? chunk.text,
            embedding: embeddings[index] ?? []
          })),
          audio
        );
      } catch (error) {
        if (audio && audio.file !== previousAudio) {
          await rm(join(this.options.audioStorageDirectory!, audio.file), { force: true });
        }
        throw error;
      }
      if (previousAudio && previousAudio !== audio?.file && this.options.audioStorageDirectory) {
        await rm(join(this.options.audioStorageDirectory, previousAudio), { force: true });
      }
    } catch (error) {
      await this.store.failTranscription(episode.id, messageOf(error), {
        permanent: error instanceof PermanentError,
        maxAttempts: this.options.maxTranscriptionAttempts
      });
      throw error;
    } finally {
      this.currentEpisodeId = null;
      await rm(workDirectory, { recursive: true, force: true });
    }

    await this.summarizeEpisode({ ...episode, durationSec: episode.durationSec ?? durationSec });
  }

  /**
   * Keeps the exact file that was transcribed. Podcasts with dynamically
   * inserted ads serve different audio on every download, so transcript times
   * only match this copy.
   */
  private async keepAudio(
    episodeId: string,
    audioPath: string,
    download: { bytes: number; mimeType: string }
  ): Promise<StoredAudio | null> {
    const directory = this.options.audioStorageDirectory;
    if (!directory) return null;
    await mkdir(directory, { recursive: true });
    const file = `${episodeId}${AUDIO_EXTENSIONS[download.mimeType] ?? ".audio"}`;
    await moveFile(audioPath, join(directory, file));
    return { file, mimeType: download.mimeType, bytes: download.bytes };
  }

  /**
   * Summary and chapters help with overview questions, but the transcript is
   * usable without them, so a failure here never fails the episode.
   */
  private async summarizeEpisode(episode: EpisodeRecord): Promise<void> {
    try {
      const segments = await this.store.getTranscript(episode.id);
      if (segments.length === 0) return;
      const durationSec = Math.max(episode.durationSec ?? 0, segments.at(-1)?.endSec ?? 0);
      const result = await this.aiClient.summarizeTranscript({ title: episode.title, segments, durationSec });
      const embeddings = await this.aiClient.embedTexts(
        result.chapters.map((chapter) => `${chapter.title}. ${chapter.summary}`)
      );
      if (embeddings.length !== result.chapters.length ||
          embeddings.some((embedding) => embedding.length !== 1536)) {
        throw new Error("Chapter embeddings are invalid");
      }
      await this.store.saveSummary(episode.id, {
        language: result.language,
        summary: result.summary,
        chapters: result.chapters.map((chapter, index) => ({ ...chapter, embedding: embeddings[index] ?? [] }))
      });
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error(`Summary failed for episode ${episode.id}: ${messageOf(error)}`);
      await this.store.failSummary(episode.id).catch(() => {});
    }
  }
}
