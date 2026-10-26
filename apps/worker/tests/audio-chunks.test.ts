import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { parseSilenceLog, planChunkBoundaries, prepareAudioChunks } from "../src/audio-chunks.js";

/** Mono 16 kHz WAV; `silences` are [start, end] ranges in seconds with no signal. */
function wavFixture(durationSec: number, silences: [number, number][] = []): Buffer {
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
    const time = index / sampleRate;
    const silent = silences.some(([start, end]) => time >= start && time < end);
    const sample = silent ? 0 : Math.round(8000 * Math.sin(2 * Math.PI * 440 * time));
    buffer.writeInt16LE(sample, 44 + index * 2);
  }
  return buffer;
}

const directories: string[] = [];

async function fixtureFile(buffer: Buffer): Promise<{ path: string; workDirectory: string }> {
  const workDirectory = await mkdtemp(join(tmpdir(), "audio-chunks-test-"));
  directories.push(workDirectory);
  const path = join(workDirectory, "input.wav");
  await writeFile(path, buffer);
  return { path, workDirectory };
}

afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("planChunkBoundaries", () => {
  const options = { targetSec: 20, minSec: 10, maxSec: 30 };

  it("cuts at the pause closest to the target length", () => {
    const cuts = planChunkBoundaries(70, [
      { start: 12, end: 12.6 }, { start: 22, end: 22.4 }, { start: 47, end: 47.8 }
    ], options);
    expect(cuts).toEqual([22.2, 47.4]);
  });

  it("falls back to the target length when no pause is in range", () => {
    expect(planChunkBoundaries(65, [], options)).toEqual([20, 40]);
  });

  it("never leaves a final clip shorter than the minimum", () => {
    const cuts = planChunkBoundaries(31, [{ start: 29.5, end: 30 }], options);
    expect(cuts).toEqual([20]);
    expect(31 - cuts.at(-1)!).toBeGreaterThanOrEqual(10);
  });

  it("does not cut audio that fits in one clip", () => {
    expect(planChunkBoundaries(30, [{ start: 10, end: 11 }], options)).toEqual([]);
  });
});

describe("parseSilenceLog", () => {
  it("pairs silence starts and ends from FFmpeg output", () => {
    const log = [
      "[silencedetect @ 0x1] silence_start: 1.5",
      "[silencedetect @ 0x1] silence_end: 2.25 | silence_duration: 0.75",
      "[silencedetect @ 0x1] silence_start: -0.01",
      "[silencedetect @ 0x1] silence_end: 0.5 | silence_duration: 0.51",
      "[silencedetect @ 0x1] silence_start: 9"
    ].join("\n");
    expect(parseSilenceLog(log)).toEqual([{ start: 1.5, end: 2.25 }, { start: 0, end: 0.5 }]);
  });
});

describe("audio segmentation", () => {
  it("splits real audio at pauses into small files with contiguous measured offsets", async () => {
    const { path, workDirectory } = await fixtureFile(wavFixture(65, [[17, 18], [41, 42]]));
    const result = await prepareAudioChunks(path, workDirectory);
    expect(result.durationSec).toBeCloseTo(65, 1);
    expect(result.chunks).toHaveLength(3);
    expect(result.chunks[0]?.startSec).toBe(0);
    expect(result.chunks[1]?.startSec).toBeCloseTo(17.5, 0);
    expect(result.chunks[2]?.startSec).toBeCloseTo(41.5, 0);

    let previousEnd = 0;
    for (const chunk of result.chunks) {
      expect(chunk.startSec).toBeCloseTo(previousEnd, 3);
      expect(chunk.endSec).toBeGreaterThan(chunk.startSec);
      expect(chunk.endSec - chunk.startSec).toBeLessThan(30.2);
      expect((await stat(chunk.path)).size).toBeLessThan(25 * 1024 * 1024);
      expect((await readFile(chunk.path)).toString("ascii", 0, 4)).toBe("RIFF");
      expect(chunk.mimeType).toBe("audio/wav");
      previousEnd = chunk.endSec;
    }
  }, 30_000);

  it("cuts at the target length when the audio has no pauses", async () => {
    const { path, workDirectory } = await fixtureFile(wavFixture(65));
    const result = await prepareAudioChunks(path, workDirectory);
    expect(result.chunks.map((chunk) => Math.round(chunk.startSec))).toEqual([0, 20, 40]);
  }, 30_000);

  it("gives an actionable error when the audio tools are missing", async () => {
    const { path, workDirectory } = await fixtureFile(wavFixture(1));
    await expect(prepareAudioChunks(path, workDirectory, {
      ffprobePath: "/missing-podcast-test-tool/ffprobe"
    })).rejects.toThrow("requires ffmpeg and ffprobe");
  });

  it("rejects an empty download before invoking audio tools", async () => {
    const { path, workDirectory } = await fixtureFile(Buffer.alloc(0));
    await expect(prepareAudioChunks(path, workDirectory)).rejects.toThrow("audio is empty");
  });
});
