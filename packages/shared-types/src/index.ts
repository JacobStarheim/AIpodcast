/**
 * Latest database migration the services expect. Keep this equal to the
 * prefix of the newest file in infrastructure/migrations.
 */
export const SCHEMA_VERSION = "003";

/**
 * pending: listed from the feed, transcription not requested.
 * queued: transcription requested, waiting for the worker.
 * processing: the worker is downloading, transcribing or indexing it.
 */
export type TranscriptionStatus = "pending" | "queued" | "processing" | "ready" | "failed";

export type IngestJobStatus = "queued" | "processing" | "completed" | "failed";

export interface Source {
  id: string;
  name: string;
  rssUrl: string;
  imageUrl: string | null;
  createdAt: string;
}

export interface SourceSummary extends Source {
  /** New episodes found by the periodic feed refresh are transcribed automatically. */
  autoTranscribe: boolean;
  /** When the feed was last read; null before the first import finishes. */
  lastRefreshedAt: string | null;
  episodeCount: number;
  readyEpisodeCount: number;
  lastJob: {
    status: IngestJobStatus;
    error: string | null;
    updatedAt: string;
  } | null;
}

export interface SourceListResponse {
  items: SourceSummary[];
}

export interface UpdateSourceRequest {
  autoTranscribe: boolean;
}

export interface AddSourceRequest {
  rssUrl: string;
  name?: string;
  imageUrl?: string;
}

export interface PodcastSearchResult {
  title: string;
  author: string | null;
  feedUrl: string;
  imageUrl: string | null;
  genre: string | null;
}

export interface PodcastSearchResponse {
  items: PodcastSearchResult[];
}

export interface EpisodeSummary {
  id: string;
  sourceId: string;
  sourceName: string;
  title: string;
  description: string;
  publishedAt: string;
  /** The publisher's audio URL. */
  audioUrl: string;
  /**
   * What the app should play. For transcribed episodes this is the exact file
   * that was transcribed, served by the API through a signed, expiring link;
   * transcript and citation times refer to it. Podcasts with dynamically
   * inserted ads can shift by many seconds between downloads of audioUrl.
   * A relative URL is relative to the API origin.
   */
  playbackUrl: string;
  imageUrl: string | null;
  durationSec: number | null;
  transcriptionStatus: TranscriptionStatus;
  /** Last failure reason; null unless the latest attempt failed. */
  transcriptionError: string | null;
}

export interface Chapter {
  id: string;
  title: string;
  summary: string;
  startSec: number;
  endSec: number;
}

export interface EpisodeDetail extends EpisodeSummary {
  guid: string;
  /** BCP 47 code of the spoken language, when known. */
  language: string | null;
  summary: string | null;
  chapters: Chapter[];
}

export interface Citation {
  /** Transcript segment id, or `chapter:<id>` for a chapter citation. */
  segmentId: string;
  kind: "segment" | "chapter";
  episodeId: string;
  episodeTitle: string;
  startSec: number;
  endSec: number;
  /**
   * Estimated start of the cited sentence within the passage, a little early.
   * Prefer this over startSec for "Listen from".
   */
  playFromSec: number;
  text: string;
  score: number;
}

export interface QATurn {
  question: string;
  answer: string;
}

export interface QARequest {
  questionText: string;
  /** Omit to search every ready episode in the library. */
  episodeId?: string;
  /** Current playback position in `episodeId`, for "what did they just say?". */
  positionSec?: number;
  /** Earlier turns of this conversation, oldest first. At most 6 are used. */
  history?: QATurn[];
  topK?: number;
}

export interface QAResponse {
  answerText: string;
  citations: Citation[];
  grounded: boolean;
  refusalReason?: string;
}

/**
 * Events of POST /v1/qa/answer/stream, sent as server-sent events
 * (`data: <json>` lines). `done` carries the authoritative response and
 * replaces any text shown from `delta` events; `error` ends the stream.
 */
export type QAStreamEvent =
  | { type: "status"; stage: "searching" | "answering" }
  | { type: "delta"; text: string }
  | { type: "done"; response: QAResponse }
  | { type: "error"; error: string; requestId?: string };

export interface EpisodeListResponse {
  items: EpisodeSummary[];
  nextCursor: string | null;
}

export interface EpisodeDetailResponse {
  episode: EpisodeDetail;
  transcriptionStatus: TranscriptionStatus;
}

export interface TranscribeEpisodeResponse {
  jobId: string | null;
  episode: EpisodeSummary;
}

export interface ApiErrorResponse {
  error: string;
  /** Machine-readable reason for some errors, e.g. `transcription_budget_exceeded`. */
  code?: string;
  requestId?: string;
}

export interface User {
  id: string;
  email: string;
  name: string;
  role: "user" | "admin";
}

export interface LoginRequest {
  email: string;
  password: string;
}

export interface LoginResponse {
  /** Send as `Authorization: Bearer <token>`. */
  token: string;
  expiresAt: string;
  user: User;
}

export interface UsageResponse {
  /** UTC day the limit applies to, YYYY-MM-DD. */
  date: string;
  usedMinutes: number;
  limitMinutes: number;
  remainingMinutes: number;
}

export { extractNameHints, htmlToText, transcriptionPrompt } from "./hints.js";
