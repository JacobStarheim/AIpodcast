import OpenAI from "openai";
import { toFile } from "openai/uploads";
import { prepareAudioChunks, type AudioChunkOptions, type PreparedAudio } from "./audio-chunks.js";
import type { RawTranscriptSegment } from "./chunking.js";

interface WorkerOpenAiConfig {
  apiKey: string;
  transcribeModel: string;
  embedModel: string;
  audioChunkOptions?: AudioChunkOptions;
}

export interface TranscriptionResult {
  durationSec: number;
  segments: RawTranscriptSegment[];
}

export interface WorkerAiClient {
  transcribeEpisodeAudio(input: {
    buffer: Buffer;
    filename: string;
    mimeType: string;
  }): Promise<TranscriptionResult>;
  embedText(text: string): Promise<number[]>;
}

interface WorkerOpenAiDependencies {
  client?: OpenAI;
  prepareAudio?: (buffer: Buffer, options?: AudioChunkOptions) => Promise<PreparedAudio>;
}

export class WorkerOpenAiClient implements WorkerAiClient {
  private readonly client: OpenAI;
  private readonly prepareAudio: NonNullable<WorkerOpenAiDependencies["prepareAudio"]>;

  constructor(
    private readonly config: WorkerOpenAiConfig,
    dependencies: WorkerOpenAiDependencies = {}
  ) {
    this.client = dependencies.client ?? new OpenAI({ apiKey: config.apiKey });
    this.prepareAudio = dependencies.prepareAudio ?? prepareAudioChunks;
  }

  async transcribeEpisodeAudio(input: {
    buffer: Buffer;
    filename: string;
    mimeType: string;
  }): Promise<TranscriptionResult> {
    const prepared = await this.prepareAudio(input.buffer, this.config.audioChunkOptions);
    const segments: RawTranscriptSegment[] = [];
    for (const chunk of prepared.chunks) {
      const file = await toFile(chunk.buffer, chunk.filename, { type: chunk.mimeType });
      // gpt-transcribe returns text JSON, without word/segment timestamps.
      const response = await this.client.audio.transcriptions.create({
        model: this.config.transcribeModel,
        file
      });
      const text = String(response.text ?? "").trim();
      if (text) {
        segments.push({ start: chunk.startSec, end: chunk.endSec, text });
      }
    }

    if (segments.length === 0) {
      throw new Error("Transcription returned no speech");
    }
    return { durationSec: prepared.durationSec, segments };
  }

  async embedText(text: string): Promise<number[]> {
    const response = await this.client.embeddings.create({
      model: this.config.embedModel,
      input: text,
      dimensions: 1536
    });

    return response.data[0]?.embedding ?? [];
  }
}
