import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const runFile = promisify(execFile);

export interface AudioChunk {
  buffer: Buffer;
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
  chunkDurationSec?: number;
  ffmpegPath?: string;
  ffprobePath?: string;
}

/**
 * Decode once into small WAV files. CSV times are the actual segment boundaries
 * in the decoded audio, not timestamps guessed from the transcript.
 */
export async function prepareAudioChunks(
  buffer: Buffer,
  options: AudioChunkOptions = {}
): Promise<PreparedAudio> {
  const chunkDurationSec = options.chunkDurationSec ?? 30;
  if (!Number.isFinite(chunkDurationSec) || chunkDurationSec < 1 || chunkDurationSec > 60) {
    throw new Error("Audio chunk duration must be between 1 and 60 seconds");
  }
  if (buffer.length === 0) {
    throw new Error("Episode audio is empty");
  }

  const directory = await mkdtemp(join(tmpdir(), "podcast-audio-"));
  try {
    const inputPath = join(directory, "input.audio");
    await writeFile(inputPath, buffer);

    const { stdout } = await runFile(options.ffprobePath ?? "ffprobe", [
      "-v", "error", "-select_streams", "a:0",
      "-show_entries", "stream=codec_type", "-of", "json", inputPath
    ], { timeout: 30_000, maxBuffer: 1024 * 1024 });
    const probe = JSON.parse(stdout) as { streams?: { codec_type?: string }[] };
    if (!probe.streams?.some((stream) => stream.codec_type === "audio")) {
      throw new Error("Episode file contains no audio stream");
    }

    await runFile(options.ffmpegPath ?? "ffmpeg", [
      "-hide_banner", "-loglevel", "error", "-nostdin",
      "-i", inputPath, "-map", "0:a:0", "-vn",
      "-af", "asetpts=PTS-STARTPTS", "-ac", "1", "-ar", "16000",
      "-c:a", "pcm_s16le", "-f", "segment",
      "-segment_time", String(chunkDurationSec),
      "-segment_list", "chunks.csv", "-segment_list_type", "csv",
      "-reset_timestamps", "1", "chunk-%05d.wav"
    ], { cwd: directory, timeout: 10 * 60_000, maxBuffer: 1024 * 1024 });

    const manifest = await readFile(join(directory, "chunks.csv"), "utf8");
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
      const chunkBuffer = await readFile(join(directory, filename));
      if (chunkBuffer.length > 25 * 1024 * 1024) {
        throw new Error("Prepared audio chunk exceeds the transcription upload limit");
      }
      chunks.push({ buffer: chunkBuffer, filename, mimeType: "audio/wav", startSec, endSec });
    }

    const durationSec = chunks.at(-1)?.endSec ?? 0;
    if (durationSec <= 0) {
      throw new Error("Episode audio has no measurable duration");
    }
    return { durationSec, chunks };
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      throw new Error("Episode transcription requires ffmpeg and ffprobe on PATH");
    }
    throw error;
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
