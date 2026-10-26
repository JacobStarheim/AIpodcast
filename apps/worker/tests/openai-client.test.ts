import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import OpenAI from "openai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { WorkerOpenAiClient } from "../src/openai-client.js";

const directories: string[] = [];

afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function fixture(responses: string[], options: { concurrency?: number; delays?: number[] } = {}) {
  const workDirectory = await mkdtemp(join(tmpdir(), "openai-client-test-"));
  directories.push(workDirectory);
  const chunks = [
    { filename: "chunk-00000.wav", startSec: 0, endSec: 30.016 },
    { filename: "chunk-00001.wav", startSec: 30.016, endSec: 42.25 }
  ];
  for (const chunk of chunks) await writeFile(join(workDirectory, chunk.filename), chunk.filename);

  const sdk = new OpenAI({ apiKey: "test-key" });
  let inFlight = 0;
  let maxInFlight = 0;
  const create = vi.spyOn(sdk.audio.transcriptions, "create");
  // Answer by clip name: concurrent requests may start in any order.
  create.mockImplementation((async (request: { file: File }) => {
    const index = chunks.findIndex((chunk) => chunk.filename === request.file.name);
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    await new Promise((resolve) => setTimeout(resolve, options.delays?.[index] ?? 0));
    inFlight -= 1;
    return { text: responses[index] };
  }) as never);
  const client = new WorkerOpenAiClient(
    {
      apiKey: "test-key",
      transcribeModel: "gpt-transcribe",
      embedModel: "text-embedding-3-small",
      transcribeConcurrency: options.concurrency
    },
    {
      client: sdk,
      prepareAudio: async () => ({
        durationSec: 42.25,
        chunks: chunks.map((chunk) => ({ ...chunk, path: join(workDirectory, chunk.filename), mimeType: "audio/wav" }))
      })
    }
  );
  return { client, create, sdk, input: { path: join(workDirectory, "episode.mp3"), workDirectory }, maxInFlight: () => maxInFlight };
}

describe("episode transcription", () => {
  it("uses the modern model's JSON contract and actual audio clip boundaries", async () => {
    const { client, create, input } = await fixture(["  Opening remarks. ", "Second topic."]);
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

  it("transcribes clips concurrently but keeps their order", async () => {
    const { client, input, maxInFlight } = await fixture(["Slow first clip.", "Fast second clip."], {
      concurrency: 2,
      delays: [30, 0]
    });
    const result = await client.transcribeEpisodeAudio(input);
    expect(maxInFlight()).toBe(2);
    expect(result.segments.map((segment) => segment.text)).toEqual(["Slow first clip.", "Fast second clip."]);
  });

  it("keeps offsets after a silent clip instead of shifting later citations", async () => {
    const { client, input } = await fixture(["  ", "Speech after silence."]);
    const result = await client.transcribeEpisodeAudio(input);
    expect(result.segments).toEqual([
      { start: 30.016, end: 42.25, text: "Speech after silence." }
    ]);
  });

  it("rejects an episode when every clip returns an empty transcript", async () => {
    const { client, input } = await fixture(["", "\n"]);
    await expect(client.transcribeEpisodeAudio(input)).rejects.toThrow("no speech");
  });
});

describe("embeddings", () => {
  it("sends texts in batches and returns embeddings in input order", async () => {
    const { client, sdk } = await fixture([]);
    const create = vi.spyOn(sdk.embeddings, "create").mockImplementation((async (request: { input: string[] }) => ({
      data: request.input
        .map((text, index) => ({ index, embedding: [Number(text.split("-")[1])], object: "embedding" }))
        .reverse()
    })) as never);

    const texts = Array.from({ length: 70 }, (_, index) => `text-${index}`);
    const result = await client.embedTexts(texts);

    expect(create).toHaveBeenCalledTimes(2);
    expect((create.mock.calls[0]?.[0] as { input: string[] }).input).toHaveLength(64);
    expect(create.mock.calls[0]?.[0]).toMatchObject({ model: "text-embedding-3-small", dimensions: 1536 });
    expect(result.map((embedding) => embedding[0])).toEqual(texts.map((_, index) => index));
  });
});
