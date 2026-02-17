import OpenAI from "openai";
import { toFile } from "openai/uploads";
import type { AIClient, RetrievedSegment } from "./types.js";

interface OpenAIClientConfig {
  apiKey: string;
  transcribeModel: string;
  embedModel: string;
  chatModel: string;
  ttsModel: string;
}

interface GroundedAnswerPayload {
  answerText: string;
  citationIndices: number[];
}

function safeParseGroundedPayload(raw: string): GroundedAnswerPayload {
  try {
    const parsed = JSON.parse(raw) as Partial<GroundedAnswerPayload>;
    const answerText = typeof parsed.answerText === "string" ? parsed.answerText.trim() : "";
    const citationIndices = Array.isArray(parsed.citationIndices)
      ? parsed.citationIndices.filter((value): value is number => Number.isInteger(value) && value >= 0)
      : [];
    return { answerText, citationIndices };
  } catch {
    return { answerText: "", citationIndices: [] };
  }
}

function buildContext(segments: RetrievedSegment[]): string {
  return segments
    .map(
      (segment, index) =>
        `[${index}] episode="${segment.episodeTitle}" start=${segment.startSec.toFixed(2)} end=${segment.endSec.toFixed(2)}\n${segment.text}`
    )
    .join("\n\n");
}

export class OpenAiClient implements AIClient {
  private readonly client: OpenAI;

  constructor(private readonly config: OpenAIClientConfig) {
    this.client = new OpenAI({ apiKey: config.apiKey });
  }

  async transcribeAudio(input: {
    buffer: Buffer;
    filename: string;
    mimeType: string;
  }): Promise<{ text: string; durationMs: number }> {
    const file = await toFile(input.buffer, input.filename, { type: input.mimeType });

    const response = await this.client.audio.transcriptions.create({
      model: this.config.transcribeModel,
      file,
      response_format: "verbose_json"
    });

    const durationSec = "duration" in response ? Number(response.duration ?? 0) : 0;

    return {
      text: String(response.text ?? "").trim(),
      durationMs: Math.max(0, Math.round(durationSec * 1000))
    };
  }

  async embedText(text: string): Promise<number[]> {
    const response = await this.client.embeddings.create({
      model: this.config.embedModel,
      input: text
    });

    return response.data[0]?.embedding ?? [];
  }

  async answerGrounded(input: {
    questionText: string;
    segments: RetrievedSegment[];
  }): Promise<{ answerText: string; citationIndices: number[] }> {
    const completion = await this.client.chat.completions.create({
      model: this.config.chatModel,
      temperature: 0.1,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content:
            "You answer podcast questions using only provided transcript evidence. Return JSON only with keys answerText and citationIndices. If evidence is insufficient, return {\"answerText\":\"\",\"citationIndices\":[]}. Every non-empty answerText must include at least one citation index."
        },
        {
          role: "user",
          content: `Question:\n${input.questionText}\n\nEvidence chunks:\n${buildContext(input.segments)}`
        }
      ]
    });

    const content = completion.choices[0]?.message?.content ?? "{}";
    return safeParseGroundedPayload(content);
  }

  async synthesizeSpeech(text: string): Promise<{ audioBase64: string; mimeType: "audio/mpeg" }> {
    const response = await this.client.audio.speech.create({
      model: this.config.ttsModel,
      voice: "alloy",
      input: text,
      format: "mp3"
    });

    const audioBuffer = Buffer.from(await response.arrayBuffer());
    return {
      audioBase64: audioBuffer.toString("base64"),
      mimeType: "audio/mpeg"
    };
  }
}
