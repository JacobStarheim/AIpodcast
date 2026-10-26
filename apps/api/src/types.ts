import type {
  Citation,
  EpisodeDetail,
  EpisodeListResponse,
  EpisodeSummary,
  IngestJobStatus,
  PodcastSearchResult,
  QATurn,
  Source,
  SourceSummary,
  TranscriptionStatus
} from "@podcast/shared-types";

export interface IngestJob {
  id: string;
  sourceId: string | null;
  maxEpisodesPerSource: number | null;
  status: IngestJobStatus;
  createdAt: string;
}

export interface RetrievedSegment extends Citation {}

/** A passage or chapter offered to the answer model. */
export interface Evidence extends Citation {
  /** Part of what the listener heard just before asking. */
  recentlyHeard?: boolean;
}

export interface Repository {
  createSource(input: { name: string; rssUrl: string }): Promise<Source>;
  /** Adds the feed (or finds the active one with that URL) and queues an episode-list import. */
  addSource(input: { name: string; rssUrl: string; imageUrl: string | null }): Promise<{
    source: SourceSummary;
    created: boolean;
  }>;
  listSources(): Promise<SourceSummary[]>;
  enqueueIngestJob(input: { sourceId?: string; maxEpisodesPerSource?: number }): Promise<IngestJob>;
  listEpisodes(input: {
    sourceId?: string;
    q?: string;
    statuses?: TranscriptionStatus[];
    limit: number;
    cursor?: string;
  }): Promise<EpisodeListResponse>;
  getEpisodeById(episodeId: string): Promise<EpisodeDetail | null>;
  /** null when the episode does not exist; jobId null when nothing needed queueing. */
  requestTranscription(episodeId: string): Promise<{ episode: EpisodeSummary; jobId: string | null } | null>;
  /** Spoken languages of ready episodes, most common first. */
  listReadyLanguages(): Promise<string[]>;
  searchSegments(input: {
    embedding: number[];
    episodeId?: string;
    topK: number;
  }): Promise<RetrievedSegment[]>;
  /** Keyword search; any of the terms may match. */
  searchSegmentsByText(input: {
    terms: string[];
    episodeId?: string;
    topK: number;
  }): Promise<RetrievedSegment[]>;
  /** Passages overlapping [fromSec, toSec], in time order. */
  segmentsBetween(input: {
    episodeId: string;
    fromSec: number;
    toSec: number;
    limit: number;
  }): Promise<RetrievedSegment[]>;
  searchChapters(input: { embedding: number[]; topK: number }): Promise<RetrievedSegment[]>;
  logQaEvent(input: {
    episodeId?: string;
    questionText: string;
    grounded: boolean;
    latencyMs: number;
  }): Promise<void>;
}

export interface SearchPlan {
  /** Queries phrased like the transcript, including translations. */
  queries: string[];
  /** The question is about the episode as a whole rather than one detail. */
  overview: boolean;
}

export interface AIClient {
  transcribeAudio(input: {
    buffer: Buffer;
    filename: string;
    mimeType: string;
  }): Promise<{ text: string; durationMs: number }>;
  /** One embedding per text, in input order. */
  embedTexts(texts: string[]): Promise<number[][]>;
  planSearch(input: {
    questionText: string;
    history: QATurn[];
    transcriptLanguages: string[];
    episodeTitle: string | null;
    signal?: AbortSignal;
  }): Promise<SearchPlan>;
  answerGrounded(input: {
    questionText: string;
    evidence: Evidence[];
    history: QATurn[];
    episodeSummary: string | null;
  }): Promise<{ answerText: string; citationIndices: number[] }>;
  synthesizeSpeech(text: string): Promise<{ audioBase64: string; mimeType: "audio/mpeg" | "audio/wav" }>;
}

export interface PodcastDirectory {
  search(term: string, country: string): Promise<PodcastSearchResult[]>;
}
