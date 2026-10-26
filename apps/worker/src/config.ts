import { resolve } from "node:path";
import dotenv from "dotenv";

dotenv.config();

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function nonNegativeNumber(name: string, fallback: number): number {
  const raw = process.env[name];
  const value = raw === undefined || raw === "" ? fallback : Number(raw);
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${name} must be zero or a positive number`);
  }
  return value;
}

function positiveNumber(name: string, fallback: number): number {
  const raw = process.env[name];
  const value = raw === undefined || raw === "" ? fallback : Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a positive number`);
  }
  return value;
}

export interface WorkerConfig {
  databaseUrl: string;
  openAiApiKey: string;
  transcribeModel: string;
  embedModel: string;
  chatModel: string;
  pollIntervalMs: number;
  maxEpisodeAudioMb: number;
  defaultMaxEpisodesPerSource: number;
  maxTranscriptionAttempts: number;
  transcribeConcurrency: number;
  audioChunkTargetSec: number;
  allowPrivateNetwork: boolean;
  staleJobSec: number;
  audioStorageDirectory: string;
  feedRefreshSec: number;
  dailyTranscriptionSec: number;
  ffmpegPath: string;
  ffprobePath: string;
}

export function loadConfig(): WorkerConfig {
  return {
    databaseUrl: process.env.DATABASE_URL ?? "postgresql://podcast:podcast@localhost:5432/podcast_ai",
    openAiApiKey: required("OPENAI_API_KEY"),
    transcribeModel: process.env.OPENAI_TRANSCRIBE_MODEL ?? "gpt-transcribe",
    embedModel: process.env.OPENAI_EMBED_MODEL ?? "text-embedding-3-small",
    chatModel: process.env.OPENAI_CHAT_MODEL ?? "gpt-6-luna",
    pollIntervalMs: positiveNumber("WORKER_POLL_INTERVAL_MS", 10_000),
    maxEpisodeAudioMb: positiveNumber("MAX_EPISODE_AUDIO_MB", 500),
    defaultMaxEpisodesPerSource: positiveNumber("DEFAULT_MAX_EPISODES_PER_SOURCE", 10),
    maxTranscriptionAttempts: Math.floor(positiveNumber("MAX_TRANSCRIPTION_ATTEMPTS", 3)),
    transcribeConcurrency: Math.floor(positiveNumber("TRANSCRIBE_CONCURRENCY", 4)),
    audioChunkTargetSec: positiveNumber("AUDIO_CHUNK_TARGET_SEC", 20),
    allowPrivateNetwork: process.env.ALLOW_PRIVATE_NETWORK_FEEDS === "true",
    staleJobSec: positiveNumber("STALE_JOB_MINUTES", 10) * 60,
    // npm runs the workspace from apps/worker, so this is <repo>/.local/audio.
    audioStorageDirectory: resolve(process.env.AUDIO_STORAGE_DIR || "../../.local/audio"),
    // 0 disables the periodic refresh / the daily limit.
    feedRefreshSec: nonNegativeNumber("FEED_REFRESH_MINUTES", 60) * 60,
    dailyTranscriptionSec: nonNegativeNumber("DAILY_TRANSCRIPTION_MINUTES", 180) * 60,
    ffmpegPath: process.env.FFMPEG_PATH ?? "ffmpeg",
    ffprobePath: process.env.FFPROBE_PATH ?? "ffprobe"
  };
}
