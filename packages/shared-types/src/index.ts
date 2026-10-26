/**
 * Latest database migration the services expect. Keep this equal to the
 * prefix of the newest file in infrastructure/migrations.
 */
export const SCHEMA_VERSION = "002";

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
  audioUrl: string;
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
  requestId?: string;
}
