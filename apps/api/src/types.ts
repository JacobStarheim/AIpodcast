import type { Citation, EpisodeDetail, EpisodeListResponse, Source } from "@podcast/shared-types";

export interface IngestJob {
  id: string;
  sourceId: string | null;
  maxEpisodesPerSource: number | null;
  status: "queued" | "processing" | "completed" | "failed";
  createdAt: string;
}

export interface RetrievedSegment extends Citation {}

export interface Repository {
  createSource(input: { name: string; rssUrl: string }): Promise<Source>;
  enqueueIngestJob(input: { sourceId?: string; maxEpisodesPerSource?: number }): Promise<IngestJob>;
  listEpisodes(input: {
    sourceId?: string;
    q?: string;
    limit: number;
    cursor?: string;
  }): Promise<EpisodeListResponse>;
  getEpisodeById(episodeId: string): Promise<EpisodeDetail | null>;
  searchSegments(input: {
    embedding: number[];
    episodeId?: string;
    topK: number;
  }): Promise<RetrievedSegment[]>;
  logQaEvent(input: {
    episodeId?: string;
    questionText: string;
    grounded: boolean;
    latencyMs: number;
  }): Promise<void>;
}

export interface AIClient {
  transcribeAudio(input: {
    buffer: Buffer;
    filename: string;
    mimeType: string;
  }): Promise<{ text: string; durationMs: number }>;
  embedText(text: string): Promise<number[]>;
  answerGrounded(input: {
    questionText: string;
    segments: RetrievedSegment[];
  }): Promise<{ answerText: string; citationIndices: number[] }>;
  synthesizeSpeech(text: string): Promise<{ audioBase64: string; mimeType: "audio/mpeg" }>;
}

