import dotenv from "dotenv";

dotenv.config();

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

export interface ApiConfig {
  port: number;
  adminKey: string;
  appApiKey: string;
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
  trustProxy: string | false;
}

export function loadConfig(): ApiConfig {
  const country = (process.env.PODCAST_SEARCH_COUNTRY ?? "US").toUpperCase();
  if (!/^[A-Z]{2}$/.test(country)) {
    throw new Error("PODCAST_SEARCH_COUNTRY must be a two-letter country code");
  }
  return {
    port: Number(process.env.PORT ?? 4000),
    adminKey: required("ADMIN_KEY"),
    appApiKey: required("APP_API_KEY"),
    databaseUrl: process.env.DATABASE_URL ?? "postgresql://podcast:podcast@localhost:5432/podcast_ai",
    openAiApiKey: required("OPENAI_API_KEY"),
    transcribeModel: process.env.OPENAI_TRANSCRIBE_MODEL ?? "gpt-transcribe",
    embedModel: process.env.OPENAI_EMBED_MODEL ?? "text-embedding-3-small",
    chatModel: process.env.OPENAI_CHAT_MODEL ?? "gpt-6-luna",
    planModel: process.env.OPENAI_PLAN_MODEL || process.env.OPENAI_CHAT_MODEL || "gpt-6-luna",
    ttsModel: process.env.OPENAI_TTS_MODEL ?? "gpt-realtime-2.1-mini",
    minGroundingScore: Number(process.env.MIN_GROUNDING_SCORE ?? 0.45),
    podcastSearchCountry: country,
    corsOrigins: (process.env.CORS_ORIGINS ?? "").split(",").map((origin) => origin.trim()).filter(Boolean),
    trustProxy: process.env.TRUST_PROXY || false
  };
}
