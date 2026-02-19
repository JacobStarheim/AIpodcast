import dotenv from "dotenv";

dotenv.config();

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

export interface WorkerConfig {
  databaseUrl: string;
  openAiApiKey: string;
  transcribeModel: string;
  embedModel: string;
  pollIntervalMs: number;
  maxEpisodeAudioMb: number;
  defaultMaxEpisodesPerSource: number;
}

export function loadConfig(): WorkerConfig {
  return {
    databaseUrl: process.env.DATABASE_URL ?? "postgresql://podcast:podcast@localhost:5432/podcast_ai",
    openAiApiKey: required("OPENAI_API_KEY"),
    transcribeModel: process.env.OPENAI_TRANSCRIBE_MODEL ?? "gpt-4o-mini-transcribe",
    embedModel: process.env.OPENAI_EMBED_MODEL ?? "text-embedding-3-small",
    pollIntervalMs: Number(process.env.WORKER_POLL_INTERVAL_MS ?? 10_000),
    maxEpisodeAudioMb: Number(process.env.MAX_EPISODE_AUDIO_MB ?? 80),
    defaultMaxEpisodesPerSource: Number(process.env.DEFAULT_MAX_EPISODES_PER_SOURCE ?? 10)
  };
}
