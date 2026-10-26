import { createHash } from "node:crypto";
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

/**
 * Express reads a numeric string as an IP address, so "1" must become the
 * number of proxy hops. Other values (true, "loopback", "uniquelocal", CIDRs)
 * pass through.
 */
export function parseTrustProxy(raw: string | undefined): boolean | number | string {
  if (!raw) return false;
  if (/^\d+$/.test(raw)) return Number(raw);
  if (raw === "true" || raw === "false") return raw === "true";
  return raw;
}

export interface ApiConfig {
  port: number;
  adminKey: string;
  appApiKey: string | undefined;
  databaseUrl: string;
  openAiApiKey: string;
  transcribeModel: string;
  embedModel: string;
  chatModel: string;
  planModel: string;
  ttsModel: string;
  minGroundingScore: number;
  podcastSearchCountry: string;
  corsOrigins: string[];
  trustProxy: boolean | number | string;
  audioStorageDirectory: string;
  mediaUrlSecret: string;
  publicBaseUrl: string;
  dailyTranscriptionSec: number;
}

export function loadConfig(): ApiConfig {
  const country = (process.env.PODCAST_SEARCH_COUNTRY ?? "US").toUpperCase();
  if (!/^[A-Z]{2}$/.test(country)) {
    throw new Error("PODCAST_SEARCH_COUNTRY must be a two-letter country code");
  }
  const adminKey = required("ADMIN_KEY");
  const dailyMinutes = Number(process.env.DAILY_TRANSCRIPTION_MINUTES ?? 180);
  if (!Number.isFinite(dailyMinutes) || dailyMinutes < 0) {
    throw new Error("DAILY_TRANSCRIPTION_MINUTES must be zero or a positive number");
  }
  return {
    port: Number(process.env.PORT ?? 4000),
    adminKey,
    appApiKey: process.env.APP_API_KEY || undefined,
    databaseUrl: process.env.DATABASE_URL ?? "postgresql://podcast:podcast@localhost:5432/podcast_ai",
    openAiApiKey: required("OPENAI_API_KEY"),
    transcribeModel: process.env.OPENAI_TRANSCRIBE_MODEL ?? "gpt-transcribe",
    embedModel: process.env.OPENAI_EMBED_MODEL ?? "text-embedding-3-small",
    chatModel: process.env.OPENAI_CHAT_MODEL ?? "gpt-6-luna",
    // Measured in docs/verification.md: about twice as fast as gpt-6-luna for
    // this step with the same answer quality on the eval set.
    planModel: process.env.OPENAI_PLAN_MODEL || "gpt-5.4-mini",
    ttsModel: process.env.OPENAI_TTS_MODEL ?? "gpt-realtime-2.1-mini",
    minGroundingScore: Number(process.env.MIN_GROUNDING_SCORE ?? 0.45),
    podcastSearchCountry: country,
    corsOrigins: (process.env.CORS_ORIGINS ?? "").split(",").map((origin) => origin.trim()).filter(Boolean),
    trustProxy: parseTrustProxy(process.env.TRUST_PROXY),
    // npm runs the workspace from apps/api, so this is <repo>/.local/audio.
    audioStorageDirectory: resolve(process.env.AUDIO_STORAGE_DIR || "../../.local/audio"),
    // Without a dedicated secret, derive one so existing setups keep working.
    mediaUrlSecret: process.env.MEDIA_URL_SECRET ||
      createHash("sha256").update(`media-url:${adminKey}`).digest("base64url"),
    publicBaseUrl: process.env.PUBLIC_BASE_URL ?? "",
    dailyTranscriptionSec: dailyMinutes * 60
  };
}
