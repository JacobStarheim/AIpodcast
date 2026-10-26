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
  TranscriptionStatus,
  User
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

export interface LoginUser extends User {
  passwordHash: string;
  disabled: boolean;
}

export interface Repository {
  /** Fails with HttpError 409 when the email is taken. */
  createUser(input: { email: string; name: string; passwordHash: string; role: User["role"] }): Promise<User>;
  findUserForLogin(email: string): Promise<LoginUser | null>;
  createSession(input: { userId: string; tokenHash: string; expiresAt: Date }): Promise<void>;
  /** The user of a valid, unexpired session whose account is enabled. */
  findSessionUser(tokenHash: string): Promise<User | null>;
  deleteSession(tokenHash: string): Promise<void>;
  getTranscribedSecondsToday(): Promise<number>;
  updateSource(sourceId: string, input: { autoTranscribe: boolean }): Promise<SourceSummary | null>;
  /** Queues transcription even for a ready episode; null when it does not exist. */
  retranscribeEpisode(episodeId: string): Promise<{ jobId: string } | null>;
  getEpisodeAudio(episodeId: string): Promise<{ file: string; mimeType: string } | null>;
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
  /** The given passages and the passages directly before and after each, in time order per hit. */
  withNeighbours(hits: RetrievedSegment[]): Promise<RetrievedSegment[]>;
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
  /** BCP 47 code of the question's language, when the planner gave one. */
  language?: string | null;
}

/** The answer model's citation: an evidence index and a few words quoted from it. */
export interface CitedEvidence {
  index: number;
  quote: string;
}

export interface GroundedAnswer {
  answerText: string;
  citations: CitedEvidence[];
}

export interface AIClient {
  transcribeAudio(input: {
    buffer: Buffer;
    filename: string;
    mimeType: string;
    /** Names and titles as spelling hints. */
    prompt?: string;
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
  /** With onDelta, the answer text is streamed to it as it is written. */
  answerGrounded(input: {
    questionText: string;
    /** BCP 47 code of the question's language, when known. */
    questionLanguage?: string | null;
    evidence: Evidence[];
    history: QATurn[];
    episodeSummary: string | null;
    onDelta?: (text: string) => void;
    signal?: AbortSignal;
  }): Promise<GroundedAnswer>;
  synthesizeSpeech(text: string): Promise<{ audioBase64: string; mimeType: "audio/mpeg" | "audio/wav" }>;
}

export interface PodcastDirectory {
  search(term: string, country: string): Promise<PodcastSearchResult[]>;
}
