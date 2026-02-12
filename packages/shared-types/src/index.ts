export type TranscriptionStatus = "pending" | "ready" | "failed";

export interface Source {
  id: string;
  name: string;
  rssUrl: string;
  createdAt: string;
}

export interface EpisodeSummary {
  id: string;
  sourceId: string;
  sourceName: string;
  title: string;
  description: string;
  publishedAt: string;
  audioUrl: string;
  transcriptionStatus: TranscriptionStatus;
}

export interface EpisodeDetail extends EpisodeSummary {
  guid: string;
  durationSec: number | null;
}

export interface Citation {
  segmentId: string;
  episodeId: string;
  episodeTitle: string;
  startSec: number;
  endSec: number;
  text: string;
  score: number;
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
