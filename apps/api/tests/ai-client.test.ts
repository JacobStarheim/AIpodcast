import OpenAI from "openai";
import { describe, expect, it } from "vitest";
import { OpenAiClient } from "../src/ai-client.js";
import type { RetrievedSegment } from "../src/types.js";

const config = {
  apiKey: "test-key",
  transcribeModel: "gpt-transcribe",
  embedModel: "text-embedding-3-small",
  chatModel: "gpt-6-luna",
  ttsModel: "gpt-realtime-2.1-mini"
};

const segment: RetrievedSegment = {
  segmentId: "seg-1",
  episodeId: "ep-1",
  episodeTitle: "A real topic",
  startSec: 12,
  endSec: 20,
  text: "The team decided to test the prototype with five listeners.",
  score: 0.9
};

function responsePayload(text: string, status = "completed") {
  return {
    id: "resp-test",
    object: "response",
    status,
    output: [
      {
        id: "msg-test",
        type: "message",
        role: "assistant",
        status: "completed",
        content: [{ type: "output_text", text, annotations: [] }]
      }
    ]
  };
}

function mockClient(payload: unknown) {
  const requests: Request[] = [];
  const sdk = new OpenAI({
    apiKey: config.apiKey,
    maxRetries: 0,
    fetch: async (url, init) => {
      // The SDK probes a custom fetch implementation's FormData support.
      if (String(url) === "data:,") return new Response("");
      requests.push(new Request(url, init));
      return new Response(JSON.stringify(payload), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
  });
  return { client: new OpenAiClient(config, sdk), requests };
}

describe("OpenAI adapter contracts", () => {
  it("uploads recorded questions as JSON transcription with the audio metadata", async () => {
    const { client, requests } = mockClient({ text: " How many listeners? ", languages: [{ code: "en" }] });
    const transcription = await client.transcribeAudio({
      buffer: Buffer.from("recorded audio"),
      filename: "question.m4a",
      mimeType: "audio/mp4"
    });

    expect(transcription).toEqual({ text: "How many listeners?", durationMs: 0 });
    expect(requests[0]?.url).toBe("https://api.openai.com/v1/audio/transcriptions");
    const form = await requests[0]!.formData();
    expect(form.get("model")).toBe("gpt-transcribe");
    expect(form.get("response_format")).toBe("json");
    const file = form.get("file") as File;
    expect(file.name).toBe("question.m4a");
    expect(file.type).toBe("audio/mp4");
    expect(await file.text()).toBe("recorded audio");
  });

  it("uses Responses strict output and returns grounded citations", async () => {
    const { client, requests } = mockClient(
      responsePayload(JSON.stringify({ answerText: "Five listeners.", citationIndices: [0, 0] }))
    );
    const answer = await client.answerGrounded({ questionText: "How many listeners?", segments: [segment] });

    expect(answer).toEqual({ answerText: "Five listeners.", citationIndices: [0] });
    expect(requests[0]?.url).toBe("https://api.openai.com/v1/responses");
    const body = await requests[0]!.json();
    expect(body.model).toBe("gpt-6-luna");
    expect(body.reasoning).toEqual({ effort: "low" });
    expect(body.store).toBe(false);
    expect(body.temperature).toBeUndefined();
    expect(body.text.format.type).toBe("json_schema");
    expect(body.text.format.strict).toBe(true);
    expect(body.text.format.schema.additionalProperties).toBe(false);
    expect(body.input[1].content).toContain(segment.text);
    expect(body.input[1].content).toContain("start=12.00");
  });

  it.each([
    "{}",
    "null",
    "not JSON",
    '{"answerText":"Unsupported claim.","citationIndices":[]}',
    '{"answerText":"Unsupported claim.","citationIndices":[0,1.5]}',
    '{"answerText":"Unsupported claim.","citationIndices":[-1,0]}',
    '{"answerText":"Unsupported claim.","citationIndices":[7]}'
  ])("refuses unusable or uncited model output: %s", async (output) => {
    const { client } = mockClient(responsePayload(output));
    expect(await client.answerGrounded({ questionText: "Question", segments: [segment] })).toEqual({
      answerText: "",
      citationIndices: []
    });
  });

  it("does not accept a truncated response even if its partial text is valid JSON", async () => {
    const { client } = mockClient(
      responsePayload('{"answerText":"Five listeners.","citationIndices":[0]}', "incomplete")
    );
    await expect(client.answerGrounded({ questionText: "Question", segments: [segment] })).rejects.toThrow(
      "did not finish"
    );
  });

  it("does not request an answer when there is no evidence", async () => {
    const { client, requests } = mockClient({});
    expect(await client.answerGrounded({ questionText: "Question", segments: [] })).toEqual({
      answerText: "",
      citationIndices: []
    });
    expect(requests).toHaveLength(0);
  });

  it("keeps the embedding model compatible with existing stored vectors", async () => {
    const { client, requests } = mockClient({ data: [{ embedding: [0.2, 0.5, 0.1] }] });
    expect(await client.embedText("Question")).toEqual([0.2, 0.5, 0.1]);
    const body = await requests[0]!.json();
    expect(body.model).toBe("text-embedding-3-small");
  });

  it("fails explicitly if embeddings are missing instead of querying with an empty vector", async () => {
    const { client } = mockClient({ data: [] });
    await expect(client.embedText("Question")).rejects.toThrow("invalid embedding");
  });
});
