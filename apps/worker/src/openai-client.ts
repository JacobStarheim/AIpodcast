import OpenAI from "openai";
import { toFile } from "openai/uploads";
import type { RawTranscriptSegment } from "./chunking.js";

interface WorkerOpenAiConfig {
  apiKey: string;
  transcribeModel: string;
  embedModel: string;
}

export interface TranscriptionResult {
  durationSec: number;
  segments: RawTranscriptSegment[];
}

export class WorkerOpenAiClient {
  private readonly client: OpenAI;

  constructor(private readonly config: WorkerOpenAiConfig) {
    this.client = new OpenAI({ apiKey: config.apiKey });
  }

  async transcribeEpisodeAudio(input: {
    buffer: Buffer;
    filename: string;
    mimeType: string;
  }): Promise<TranscriptionResult> {
    const file = await toFile(input.buffer, input.filename, { type: input.mimeType });

    const response = await this.client.audio.transcriptions.create({
      model: this.config.transcribeModel,
      file,
      response_format: "verbose_json",
      timestamp_granularities: ["segment"]
    });

    const durationSec = "duration" in response ? Number(response.duration ?? 0) : 0;

    const segments = Array.isArray(response.segments)
      ? response.segments
          .map((segment) => ({
            start: Number(segment.start ?? 0),
            end: Number(segment.end ?? 0),
            text: String(segment.text ?? "").trim(),
            speaker: undefined
          }))
          .filter((segment) => segment.text.length > 0 && segment.end >= segment.start)
      : [];

    return { durationSec, segments };
  }

  async embedText(text: string): Promise<number[]> {
    const response = await this.client.embeddings.create({
      model: this.config.embedModel,
      input: text
    });

    return response.data[0]?.embedding ?? [];
  }
}
