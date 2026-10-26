import type {
  EpisodeDetail,
  EpisodeListResponse,
  EpisodeSummary,
  PodcastSearchResult,
  QATurn,
  Source,
  SourceSummary,
  TranscriptionStatus
} from "@podcast/shared-types";
import type {
  AIClient,
  Evidence,
  IngestJob,
  PodcastDirectory,
  Repository,
  RetrievedSegment,
  SearchPlan
} from "../src/types.js";

export const EPISODE_ID = "11111111-1111-4111-8111-111111111111";
export const PENDING_EPISODE_ID = "22222222-2222-4222-8222-222222222222";
export const SOURCE_ID = "33333333-3333-4333-8333-333333333333";
export const MISSING_ID = "44444444-4444-4444-8444-444444444444";
export const APP_KEY = "test-app-key";
export const AUTH = { Authorization: `Bearer ${APP_KEY}` };

export function segment(fields: Partial<RetrievedSegment> = {}): RetrievedSegment {
  return {
    segmentId: "seg_1",
    kind: "segment",
    episodeId: EPISODE_ID,
    episodeTitle: "Episode One",
    startSec: 120,
    endSec: 152,
    text: "The host explains the prototype architecture and citation strategy.",
    score: 0.9,
    ...fields
  };
}

export class FakeRepository implements Repository {
  readonly sources: SourceSummary[] = [];
  readonly jobs: IngestJob[] = [];
  readonly qaEvents: { episodeId?: string; grounded: boolean }[] = [];
  readonly vectorQueries: { embedding: number[]; episodeId?: string; topK: number }[] = [];
  readonly textQueries: { terms: string[]; episodeId?: string }[] = [];
  readonly listQueries: Parameters<Repository["listEpisodes"]>[0][] = [];
  vectorResults: RetrievedSegment[] = [segment()];
  textResults: RetrievedSegment[] = [];
  recentSegments: RetrievedSegment[] = [segment({ segmentId: "seg_recent", startSec: 600, endSec: 620, text: "Just said." })];
  chapterResults: RetrievedSegment[] = [];
  readyLanguages = ["en"];
  episodes: EpisodeDetail[] = [
    {
      id: EPISODE_ID,
      sourceId: SOURCE_ID,
      sourceName: "Demo Source",
      guid: "guid-1",
      title: "Episode One",
      description: "A test episode",
      publishedAt: new Date("2025-02-01T00:00:00Z").toISOString(),
      audioUrl: "https://example.com/ep1.mp3",
      imageUrl: null,
      durationSec: 1800,
      transcriptionStatus: "ready",
      transcriptionError: null,
      language: "en",
      summary: "An episode about prototypes.",
      chapters: [{ id: "c1", title: "Architecture", summary: "How it is built.", startSec: 0, endSec: 900 }]
    },
    {
      id: PENDING_EPISODE_ID,
      sourceId: SOURCE_ID,
      sourceName: "Demo Source",
      guid: "guid-2",
      title: "Episode Two",
      description: "",
      publishedAt: new Date("2025-01-01T00:00:00Z").toISOString(),
      audioUrl: "https://example.com/ep2.mp3",
      imageUrl: null,
      durationSec: null,
      transcriptionStatus: "pending",
      transcriptionError: null,
      language: null,
      summary: null,
      chapters: []
    }
  ];

  async createSource(input: { name: string; rssUrl: string }): Promise<Source> {
    return { id: SOURCE_ID, name: input.name, rssUrl: input.rssUrl, imageUrl: null, createdAt: new Date().toISOString() };
  }

  async addSource(input: { name: string; rssUrl: string; imageUrl: string | null }) {
    const existing = this.sources.find((source) => source.rssUrl === input.rssUrl);
    if (existing) return { source: existing, created: false };
    const source: SourceSummary = {
      id: SOURCE_ID, name: input.name || "feeds.example.com", rssUrl: input.rssUrl, imageUrl: input.imageUrl,
      createdAt: new Date().toISOString(), episodeCount: 0, readyEpisodeCount: 0,
      lastJob: { status: "queued", error: null, updatedAt: new Date().toISOString() }
    };
    this.sources.push(source);
    return { source, created: true };
  }

  async listSources(): Promise<SourceSummary[]> {
    return this.sources;
  }

  async enqueueIngestJob(input: { sourceId?: string; maxEpisodesPerSource?: number }): Promise<IngestJob> {
    const job: IngestJob = {
      id: `job_${this.jobs.length + 1}`,
      sourceId: input.sourceId ?? null,
      maxEpisodesPerSource: input.maxEpisodesPerSource ?? null,
      status: "queued",
      createdAt: new Date().toISOString()
    };
    this.jobs.push(job);
    return job;
  }

  async listEpisodes(input: Parameters<Repository["listEpisodes"]>[0]): Promise<EpisodeListResponse> {
    this.listQueries.push(input);
    const items = this.episodes
      .filter((episode) => !input.statuses?.length || input.statuses.includes(episode.transcriptionStatus))
      .map((episode) => toSummary(episode));
    return { items, nextCursor: null };
  }

  async getEpisodeById(episodeId: string): Promise<EpisodeDetail | null> {
    return this.episodes.find((episode) => episode.id === episodeId) ?? null;
  }

  async requestTranscription(episodeId: string) {
    const episode = this.episodes.find((item) => item.id === episodeId);
    if (!episode) return null;
    if (["ready", "queued", "processing"].includes(episode.transcriptionStatus)) {
      return { episode: toSummary(episode), jobId: null };
    }
    episode.transcriptionStatus = "queued" as TranscriptionStatus;
    return { episode: toSummary(episode), jobId: "job_transcribe" };
  }

  async listReadyLanguages(): Promise<string[]> {
    return this.readyLanguages;
  }

  async searchSegments(input: { embedding: number[]; episodeId?: string; topK: number }): Promise<RetrievedSegment[]> {
    this.vectorQueries.push(input);
    const score = input.embedding[0] ?? 0;
    return this.vectorResults.map((result) => ({ ...result, score }));
  }

  async searchSegmentsByText(input: { terms: string[]; episodeId?: string; topK: number }): Promise<RetrievedSegment[]> {
    this.textQueries.push(input);
    return this.textResults;
  }

  async segmentsBetween(): Promise<RetrievedSegment[]> {
    return this.recentSegments;
  }

  async searchChapters(): Promise<RetrievedSegment[]> {
    return this.chapterResults;
  }

  async logQaEvent(input: { episodeId?: string; grounded: boolean }): Promise<void> {
    this.qaEvents.push(input);
  }
}

export function toSummary(episode: EpisodeDetail): EpisodeSummary {
  const { guid: _guid, language: _language, summary: _summary, chapters: _chapters, ...summary } = episode;
  return summary;
}

export class FakeAIClient implements AIClient {
  plan: SearchPlan = { queries: [], overview: false };
  /** Similarity the fake repository reports for passages matching a question. */
  defaultScore = 0.9;
  planCalls: { questionText: string; history: QATurn[]; transcriptLanguages: string[]; signal?: AbortSignal }[] = [];
  answerCalls: { evidence: Evidence[]; history: QATurn[]; episodeSummary: string | null }[] = [];
  embedded: string[][] = [];

  async transcribeAudio(): Promise<{ text: string; durationMs: number }> {
    return { text: "What did the host say about architecture?", durationMs: 1800 };
  }

  /** "unsupported" questions get a low similarity, everything else defaultScore. */
  async embedTexts(texts: string[]): Promise<number[][]> {
    this.embedded.push(texts);
    return texts.map((text) => (text.toLowerCase().includes("unsupported") ? [0.1] : [this.defaultScore]));
  }

  async planSearch(input: {
    questionText: string;
    history: QATurn[];
    transcriptLanguages: string[];
    signal?: AbortSignal;
  }): Promise<SearchPlan> {
    this.planCalls.push(input);
    return this.plan;
  }

  async answerGrounded(input: { evidence: Evidence[]; history: QATurn[]; episodeSummary: string | null }) {
    this.answerCalls.push(input);
    return {
      answerText: "The host said the architecture uses transcript-first retrieval with citations.",
      citationIndices: [0]
    };
  }

  async synthesizeSpeech(): Promise<{ audioBase64: string; mimeType: "audio/wav" }> {
    return {
      audioBase64: Buffer.from("fake-audio").toString("base64"),
      mimeType: "audio/wav"
    };
  }
}

export class FakeDirectory implements PodcastDirectory {
  calls: { term: string; country: string }[] = [];
  results: PodcastSearchResult[] = [{
    title: "Hard Fork", author: "The New York Times", feedUrl: "https://feeds.example.com/hardfork",
    imageUrl: "https://img.example.com/hf.jpg", genre: "Technology"
  }];

  async search(term: string, country: string): Promise<PodcastSearchResult[]> {
    this.calls.push({ term, country });
    return this.results;
  }
}
