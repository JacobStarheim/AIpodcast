import { createHmac, timingSafeEqual } from "node:crypto";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { basename, join } from "node:path";
import type { Response } from "express";
import { HttpError } from "./security.js";

/**
 * Signed, expiring links to transcribed audio. Media players cannot send an
 * Authorization header reliably, so the signature authorizes the request.
 */
export class MediaSigner {
  constructor(
    private readonly secret: string,
    private readonly publicBaseUrl = "",
    private readonly ttlSec = 12 * 60 * 60,
    private readonly now: () => number = Date.now
  ) {}

  private signature(episodeId: string, expires: number): string {
    return createHmac("sha256", this.secret).update(`${episodeId}:${expires}`).digest("base64url");
  }

  url(episodeId: string): string {
    const expires = Math.floor(this.now() / 1000) + this.ttlSec;
    const path = `/v1/media/episodes/${episodeId}?exp=${expires}&sig=${this.signature(episodeId, expires)}`;
    return `${this.publicBaseUrl.replace(/\/$/, "")}${path}`;
  }

  verify(episodeId: string, expires: unknown, signature: unknown): boolean {
    const expiresAt = Number(expires);
    if (!Number.isInteger(expiresAt) || expiresAt * 1000 < this.now() || typeof signature !== "string") return false;
    const expected = Buffer.from(this.signature(episodeId, expiresAt));
    const given = Buffer.from(signature);
    return expected.length === given.length && timingSafeEqual(expected, given);
  }
}

/** Streams a stored audio file, honouring a single HTTP Range. */
export async function sendAudioFile(
  res: Response,
  directory: string,
  file: string,
  mimeType: string,
  rangeHeader: string | undefined
): Promise<void> {
  // Stored names are "<uuid>.<ext>"; never follow anything else.
  if (basename(file) !== file) throw new HttpError(404, "not_found");
  const path = join(directory, file);
  const size = (await stat(path).catch(() => {
    throw new HttpError(404, "not_found");
  })).size;

  let start = 0;
  let end = size - 1;
  if (rangeHeader) {
    const range = /^bytes=(\d*)-(\d*)$/.exec(rangeHeader.trim());
    if (!range || (!range[1] && !range[2])) {
      throw new HttpError(416, "invalid range", { "Content-Range": `bytes */${size}` });
    }
    if (range[1]) {
      start = Number(range[1]);
      if (range[2]) end = Math.min(Number(range[2]), size - 1);
    } else {
      start = Math.max(0, size - Number(range[2]));
    }
    if (start > end || start >= size) {
      throw new HttpError(416, "invalid range", { "Content-Range": `bytes */${size}` });
    }
  }

  res.status(rangeHeader ? 206 : 200);
  res.setHeader("Content-Type", mimeType);
  res.setHeader("Accept-Ranges", "bytes");
  res.setHeader("Content-Length", String(end - start + 1));
  res.setHeader("Cache-Control", "private, max-age=3600");
  if (rangeHeader) res.setHeader("Content-Range", `bytes ${start}-${end}/${size}`);
  await new Promise<void>((resolve, reject) => {
    const stream = createReadStream(path, { start, end });
    stream.on("error", reject);
    res.on("close", () => {
      stream.destroy();
      resolve();
    });
    stream.pipe(res);
  });
}
