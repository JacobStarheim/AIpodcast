import { createReadStream } from "node:fs";
import OpenAI from "openai";
import { toFile } from "openai/uploads";
import { prepareAudioChunks, type AudioChunkOptions, type PreparedAudio } from "./audio-chunks.js";
import type { RawTranscriptSegment } from "./chunking.js";
import { mapWithConcurrency } from "./concurrency.js";
import {
  buildTranscriptPrompt,
  parseSummaryPayload,
  summaryInstructions,
  summarySchema,
  type EpisodeSummaryResult,
  type TimedText
} from "./summarize.js";

interface WorkerOpenAiConfig {
  apiKey: string;
  transcribeModel: string;
  embedModel: string;
  chatModel?: string;
  transcribeConcurrency?: number;
  audioChunkOptions?: AudioChunkOptions;
}

export interface TranscriptionResult {
  durationSec: number;
  segments: RawTranscriptSegment[];
}

export interface WorkerAiClient {
  /** Splits the audio file into clips inside workDirectory and transcribes them. */
  transcribeEpisodeAudio(input: { path: string; workDirectory: string }): Promise<TranscriptionResult>;
  /** One embedding per text, in input order. */
  embedTexts(texts: string[]): Promise<number[][]>;
  summarizeTranscript(input: {
    title: string;
    segments: TimedText[];
    durationSec: number;
  }): Promise<EpisodeSummaryResult>;
}

interface WorkerOpenAiDependencies {
  client?: OpenAI;
  prepareAudio?: (path: string, workDirectory: string, options?: AudioChunkOptions) => Promise<PreparedAudio>;
}

const EMBEDDING_BATCH_SIZE = 64;

export class WorkerOpenAiClient implements WorkerAiClient {
  private readonly client: OpenAI;
  private readonly prepareAudio: NonNullable<WorkerOpenAiDependencies["prepareAudio"]>;

  constructor(
    private readonly config: WorkerOpenAiConfig,
    dependencies: WorkerOpenAiDependencies = {}
  ) {
    this.client = dependencies.client ?? new OpenAI({ apiKey: config.apiKey, timeout: 120_000 });
    this.prepareAudio = dependencies.prepareAudio ?? prepareAudioChunks;
  }

  async transcribeEpisodeAudio(input: { path: string; workDirectory: string }): Promise<TranscriptionResult> {
    const prepared = await this.prepareAudio(input.path, input.workDirectory, this.config.audioChunkOptions);
    // Clips are independent requests; run several at once and keep their order.
    const texts = await mapWithConcurrency(
      prepared.chunks,
      this.config.transcribeConcurrency ?? 4,
      async (chunk) => {
        const file = await toFile(createReadStream(chunk.path), chunk.filename, { type: chunk.mimeType });
        // gpt-transcribe returns text JSON, without word/segment timestamps.
        const response = await this.client.audio.transcriptions.create({
          model: this.config.transcribeModel,
          file
        });
        return String(response.text ?? "").trim();
      }
    );

    const segments: RawTranscriptSegment[] = [];
    prepared.chunks.forEach((chunk, index) => {
      const text = texts[index];
      if (text) segments.push({ start: chunk.startSec, end: chunk.endSec, text });
    });
    if (segments.length === 0) {
      throw new Error("Transcription returned no speech");
    }
    return { durationSec: prepared.durationSec, segments };
  }

  async embedTexts(texts: string[]): Promise<number[][]> {
    const embeddings: number[][] = [];
    for (let offset = 0; offset < texts.length; offset += EMBEDDING_BATCH_SIZE) {
      const batch = texts.slice(offset, offset + EMBEDDING_BATCH_SIZE);
      const response = await this.client.embeddings.create({
        model: this.config.embedModel,
        input: batch,
        dimensions: 1536
      });
      const ordered = [...response.data].sort((a, b) => a.index - b.index);
      if (ordered.length !== batch.length) {
        throw new Error(`Expected ${batch.length} embeddings, received ${ordered.length}`);
      }
      embeddings.push(...ordered.map((item) => item.embedding));
    }
    return embeddings;
  }

  async summarizeTranscript(input: {
    title: string;
    segments: TimedText[];
    durationSec: number;
  }): Promise<EpisodeSummaryResult> {
    const response = await this.client.responses.create({
      model: this.config.chatModel ?? "gpt-6-luna",
      reasoning: { effort: "low" },
      store: false,
      max_output_tokens: 8192,
      text: {
        format: { type: "json_schema", name: "episode_summary", strict: true, schema: summarySchema }
      },
      input: [
        { role: "developer", content: summaryInstructions },
        { role: "user", content: buildTranscriptPrompt(input.title, input.segments) }
      ]
    });
    if (response.status !== "completed") {
      throw new Error("OpenAI did not finish the episode summary");
    }
    return parseSummaryPayload(response.output_text, input.segments, input.durationSec);
  }
}
