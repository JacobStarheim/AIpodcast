import OpenAI from "openai";
import { describe, expect, it, vi } from "vitest";
import { WorkerOpenAiClient } from "../src/openai-client.js";

function fixture(responses: string[]) {
  const sdk = new OpenAI({ apiKey: "test-key" });
  const create = vi.spyOn(sdk.audio.transcriptions, "create");
  for (const text of responses) {
    create.mockResolvedValueOnce({ text });
  }
  const client = new WorkerOpenAiClient(
    { apiKey: "test-key", transcribeModel: "gpt-transcribe", embedModel: "text-embedding-3-small" },
    {
      client: sdk,
      prepareAudio: async () => ({
        durationSec: 42.25,
        chunks: [
          { buffer: Buffer.from("first"), filename: "chunk-00000.wav", mimeType: "audio/wav", startSec: 0, endSec: 30.016 },
          { buffer: Buffer.from("second"), filename: "chunk-00001.wav", mimeType: "audio/wav", startSec: 30.016, endSec: 42.25 }
        ]
      })
    }
  );
  return { client, create };
}

const input = { buffer: Buffer.from("episode"), filename: "episode.mp3", mimeType: "audio/mpeg" };

describe("episode transcription", () => {
  it("uses the modern model's JSON contract and actual audio clip boundaries", async () => {
    const { client, create } = fixture(["  Opening remarks. ", "Second topic."]);
    const result = await client.transcribeEpisodeAudio(input);

    expect(result).toEqual({
      durationSec: 42.25,
      segments: [
        { start: 0, end: 30.016, text: "Opening remarks." },
        { start: 30.016, end: 42.25, text: "Second topic." }
      ]
    });
    expect(create).toHaveBeenCalledTimes(2);
    for (const [request] of create.mock.calls) {
      expect(request).toEqual({
        model: "gpt-transcribe",
        file: expect.objectContaining({ type: "audio/wav" })
      });
    }
  });

  it("keeps offsets after a silent clip instead of shifting later citations", async () => {
    const { client } = fixture(["  ", "Speech after silence."]);
    const result = await client.transcribeEpisodeAudio(input);
    expect(result.segments).toEqual([
      { start: 30.016, end: 42.25, text: "Speech after silence." }
    ]);
  });

  it("rejects an episode when every clip returns an empty transcript", async () => {
    const { client } = fixture(["", "\n"]);
    await expect(client.transcribeEpisodeAudio(input)).rejects.toThrow("no speech");
  });
});
