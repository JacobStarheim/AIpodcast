import { createWriteStream } from "node:fs";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { ReadableStream as WebReadableStream } from "node:stream/web";
import { PermanentError } from "./errors.js";
import { guardedFetch, type NetworkGuardOptions } from "./network-guard.js";

export interface DownloadOptions extends NetworkGuardOptions {
  maxBytes: number;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

/**
 * Streams the response to disk so long episodes never sit in memory.
 * Size is checked against Content-Length up front and again while streaming.
 */
export async function downloadToFile(
  url: string,
  destination: string,
  options: DownloadOptions
): Promise<{ bytes: number; mimeType: string }> {
  const response = await guardedFetch(
    url,
    { signal: AbortSignal.timeout(options.timeoutMs ?? 30 * 60_000) },
    options
  );
  if (!response.ok) {
    await response.body?.cancel();
    const message = `Failed to download episode audio: HTTP ${response.status}`;
    // 4xx (other than rate limiting) means the URL itself is wrong or gone.
    throw response.status >= 400 && response.status < 500 && response.status !== 429
      ? new PermanentError(message)
      : new Error(message);
  }

  const maxMb = Math.round(options.maxBytes / 1024 / 1024);
  const contentLength = Number(response.headers.get("content-length") ?? "");
  if (Number.isFinite(contentLength) && contentLength > options.maxBytes) {
    await response.body?.cancel();
    throw new PermanentError(
      `Episode audio is ${Math.round(contentLength / 1024 / 1024)} MB, above the ${maxMb} MB limit`
    );
  }
  if (!response.body) {
    throw new Error("Episode audio response is empty");
  }

  let bytes = 0;
  const limit = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      bytes += chunk.length;
      if (bytes > options.maxBytes) {
        callback(new PermanentError(`Episode audio exceeded the ${maxMb} MB limit`));
        return;
      }
      callback(null, chunk);
    }
  });
  await pipeline(
    Readable.fromWeb(response.body as WebReadableStream<Uint8Array>),
    limit,
    createWriteStream(destination)
  );
  if (bytes === 0) {
    throw new Error("Episode audio response is empty");
  }
  const mimeType = response.headers.get("content-type")?.split(";")[0]?.trim() || "audio/mpeg";
  return { bytes, mimeType };
}
