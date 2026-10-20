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
  databaseUrl: string;
  openAiApiKey: string;
  transcribeModel: string;
  embedModel: string;
  chatModel: string;
  ttsModel: string;
  minGroundingScore: number;
}

export function loadConfig(): ApiConfig {
  return {
    port: Number(process.env.PORT ?? 4000),
    adminKey: required("ADMIN_KEY"),
    databaseUrl: process.env.DATABASE_URL ?? "postgresql://podcast:podcast@localhost:5432/podcast_ai",
    openAiApiKey: required("OPENAI_API_KEY"),
    transcribeModel: process.env.OPENAI_TRANSCRIBE_MODEL ?? "gpt-transcribe",
    embedModel: process.env.OPENAI_EMBED_MODEL ?? "text-embedding-3-small",
    chatModel: process.env.OPENAI_CHAT_MODEL ?? "gpt-6-luna",
    ttsModel: process.env.OPENAI_TTS_MODEL ?? "gpt-realtime-2.1-mini",
    minGroundingScore: Number(process.env.MIN_GROUNDING_SCORE ?? 0.45)
  };
}
