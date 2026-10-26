import { execFile } from "node:child_process";
import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import { PermanentError } from "./errors.js";

const runFile = promisify(execFile);

export interface AudioChunk {
  path: string;
  filename: string;
  mimeType: string;
  startSec: number;
  endSec: number;
}

export interface PreparedAudio {
  durationSec: number;
  chunks: AudioChunk[];
}

export interface AudioChunkOptions {
  /** Preferred clip length. Clips end in a pause between 0.5× and 1.5× this. */
  targetChunkSec?: number;
  ffmpegPath?: string;
  ffprobePath?: string;
}

export interface Silence {
  start: number;
  end: number;
}

/**
 * Chooses cut points inside pauses, so words are not split between two
 * transcription requests. Each clip lasts between minSec and maxSec; without
 * a pause in that window the cut falls at targetSec.
 */
export function planChunkBoundaries(
  durationSec: number,
  silences: Silence[],
  options: { targetSec: number; minSec: number; maxSec: number }
): number[] {
  const { targetSec, minSec, maxSec } = options;
  const pauses = silences
    .map((silence) => (silence.start + silence.end) / 2)
    .filter((time) => Number.isFinite(time))
    .sort((a, b) => a - b);
  const cuts: number[] = [];
  let start = 0;
  while (durationSec - start > maxSec) {
    // Keep the last clip at least minSec long.
    const latest = Math.min(start + maxSec, durationSec - minSec);
    const preferred = start + targetSec;
    let cut = Math.min(preferred, latest);
    let bestDistance = Number.POSITIVE_INFINITY;
    for (const pause of pauses) {
      if (pause < start + minSec || pause > latest) continue;
      const distance = Math.abs(pause - preferred);
      if (distance < bestDistance) {
        bestDistance = distance;
        cut = pause;
      }
    }
    cuts.push(Number(cut.toFixed(3)));
    start = cut;
  }
  return cuts;
}

export function parseSilenceLog(log: string): Silence[] {
  const silences: Silence[] = [];
  let start: number | null = null;
  for (const match of log.matchAll(/silence_(start|end): (-?[\d.]+)/g)) {
    const value = Number(match[2]);
    if (!Number.isFinite(value)) continue;
    if (match[1] === "start") {
      start = Math.max(0, value);
    } else if (start !== null) {
      silences.push({ start, end: value });
      start = null;
    }
  }
  return silences;
}

function toolError(error: unknown): never {
  if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
    throw new Error("Episode transcription requires ffmpeg and ffprobe on PATH");
  }
  throw error;
}

async function probeDuration(inputPath: string, ffprobePath: string): Promise<number> {
  const { stdout } = await runFile(ffprobePath, [
    "-v", "error", "-select_streams", "a:0",
    "-show_entries", "stream=codec_type:format=duration", "-of", "json", inputPath
  ], { timeout: 60_000, maxBuffer: 1024 * 1024 }).catch(toolError);
  const probe = JSON.parse(stdout) as {
    streams?: { codec_type?: string }[];
    format?: { duration?: string };
  };
  if (!probe.streams?.some((stream) => stream.codec_type === "audio")) {
    throw new PermanentError("Episode file contains no audio stream");
  }
  return Number(probe.format?.duration ?? Number.NaN);
}

// Tuned on a one-hour talk show: 96% of cuts land in a pause, versus 79% at
// -35dB/0.3s. Gaps inside words are shorter than 0.2 seconds.
async function detectSilences(inputPath: string, ffmpegPath: string): Promise<Silence[]> {
  const { stderr } = await runFile(ffmpegPath, [
    "-hide_banner", "-nostats", "-nostdin", "-i", inputPath,
    "-map", "0:a:0", "-vn", "-af", "silencedetect=noise=-30dB:d=0.2", "-f", "null", "-"
  ], { timeout: 30 * 60_000, maxBuffer: 64 * 1024 * 1024 }).catch(toolError);
  return parseSilenceLog(stderr);
}

/**
 * Decodes the episode once into mono 16 kHz WAV clips cut at pauses. Clip
 * times come from FFmpeg's segment list, i.e. the real boundaries in the
 * decoded audio. Clips are written to workDirectory and read on demand.
 */
export async function prepareAudioChunks(
  inputPath: string,
  workDirectory: string,
  options: AudioChunkOptions = {}
): Promise<PreparedAudio> {
  const targetSec = options.targetChunkSec ?? 20;
  if (!Number.isFinite(targetSec) || targetSec < 2 || targetSec > 40) {
    throw new Error("Audio chunk target must be between 2 and 40 seconds");
  }
  if ((await stat(inputPath)).size === 0) {
    throw new Error("Episode audio is empty");
  }
  const ffmpegPath = options.ffmpegPath ?? "ffmpeg";
  const probedDuration = await probeDuration(inputPath, options.ffprobePath ?? "ffprobe");
  const silences = await detectSilences(inputPath, ffmpegPath);
  const cuts = Number.isFinite(probedDuration) && probedDuration > 0
    ? planChunkBoundaries(probedDuration, silences, {
        targetSec,
        minSec: targetSec * 0.5,
        maxSec: targetSec * 1.5
      })
    : [];

  const segmentArgs = cuts.length > 0
    ? ["-segment_times", cuts.join(",")]
    : ["-segment_time", String(targetSec)];
  await runFile(ffmpegPath, [
    "-hide_banner", "-loglevel", "error", "-nostdin",
    "-i", inputPath, "-map", "0:a:0", "-vn",
    "-af", "asetpts=PTS-STARTPTS", "-ac", "1", "-ar", "16000",
    "-c:a", "pcm_s16le", "-f", "segment", ...segmentArgs,
    "-segment_list", "chunks.csv", "-segment_list_type", "csv",
    "-reset_timestamps", "1", "chunk-%05d.wav"
  ], { cwd: workDirectory, timeout: 30 * 60_000, maxBuffer: 1024 * 1024 }).catch(toolError);

  const manifest = await readFile(join(workDirectory, "chunks.csv"), "utf8");
  const chunks: AudioChunk[] = [];
  for (const line of manifest.trim().split(/\r?\n/)) {
    const [filename, rawStart, rawEnd] = line.split(",");
    const startSec = Number(rawStart);
    const endSec = Number(rawEnd);
    if (!filename || !/^chunk-\d+\.wav$/.test(filename) ||
        !rawStart || !rawEnd || !Number.isFinite(startSec) ||
        !Number.isFinite(endSec) || startSec < 0 || endSec <= startSec) {
      throw new Error("FFmpeg returned invalid audio chunk timestamps");
    }
    const path = join(workDirectory, filename);
    if ((await stat(path)).size > 25 * 1024 * 1024) {
      throw new Error("Prepared audio chunk exceeds the transcription upload limit");
    }
    chunks.push({ path, filename, mimeType: "audio/wav", startSec, endSec });
  }

  const durationSec = chunks.at(-1)?.endSec ?? 0;
  if (durationSec <= 0) {
    throw new PermanentError("Episode audio has no measurable duration");
  }
  return { durationSec, chunks };
}
