import { describe, expect, it } from "vitest";
import { prepareAudioChunks } from "../src/audio-chunks.js";

function wavFixture(durationSec: number): Buffer {
  const sampleRate = 16000;
  const dataLength = durationSec * sampleRate * 2;
  const buffer = Buffer.alloc(44 + dataLength);
  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(36 + dataLength, 4);
  buffer.write("WAVEfmt ", 8);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36);
  buffer.writeUInt32LE(dataLength, 40);
  for (let index = 0; index < dataLength / 2; index += 1) {
    buffer.writeInt16LE(Math.round(1000 * Math.sin(2 * Math.PI * 440 * index / sampleRate)), 44 + index * 2);
  }
  return buffer;
}

describe("audio segmentation", () => {
  it("splits real audio into small files with contiguous measured offsets", async () => {
    const result = await prepareAudioChunks(wavFixture(65));
    expect(result.durationSec).toBeCloseTo(65, 2);
    expect(result.chunks).toHaveLength(3);
    expect(result.chunks[0]?.startSec).toBe(0);

    let previousEnd = 0;
    for (const chunk of result.chunks) {
      expect(chunk.startSec).toBeCloseTo(previousEnd, 3);
      expect(chunk.endSec).toBeGreaterThan(chunk.startSec);
      expect(chunk.endSec - chunk.startSec).toBeLessThan(30.2);
      expect(chunk.buffer.length).toBeLessThan(25 * 1024 * 1024);
      expect(chunk.buffer.toString("ascii", 0, 4)).toBe("RIFF");
      expect(chunk.mimeType).toBe("audio/wav");
      previousEnd = chunk.endSec;
    }
    expect(result.chunks[1]?.startSec).toBeCloseTo(30, 0);
    expect(result.chunks[2]?.startSec).toBeCloseTo(60, 0);
  }, 30_000);

  it("gives an actionable error when the audio tools are missing", async () => {
    await expect(prepareAudioChunks(wavFixture(1), {
      ffprobePath: "/missing-podcast-test-tool/ffprobe"
    })).rejects.toThrow("requires ffmpeg and ffprobe");
  });

  it("rejects an empty download before invoking audio tools", async () => {
    await expect(prepareAudioChunks(Buffer.alloc(0))).rejects.toThrow("audio is empty");
  });
});
