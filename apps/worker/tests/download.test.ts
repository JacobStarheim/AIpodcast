import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { downloadToFile } from "../src/download.js";
import { PermanentError } from "../src/errors.js";

const directories: string[] = [];

afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function target(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "download-test-"));
  directories.push(directory);
  return join(directory, "episode.audio");
}

function fetchReturning(response: Response): typeof fetch {
  return (async () => response) as unknown as typeof fetch;
}

function streamOf(parts: string[]): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(controller) {
      for (const part of parts) controller.enqueue(new TextEncoder().encode(part));
      controller.close();
    }
  });
}

describe("downloadToFile", () => {
  it("streams the body to disk", async () => {
    const path = await target();
    const result = await downloadToFile("https://cdn.example.com/a.mp3", path, {
      maxBytes: 100,
      allowPrivateNetwork: true,
      fetchImpl: fetchReturning(new Response(streamOf(["abc", "def"]), { headers: { "content-type": "audio/mpeg; x=1" } }))
    });
    expect(result).toEqual({ bytes: 6, mimeType: "audio/mpeg" });
    expect(await readFile(path, "utf8")).toBe("abcdef");
  });

  it("rejects a declared size above the limit before reading the body", async () => {
    const path = await target();
    const response = new Response(streamOf(["x"]), { headers: { "content-length": String(600 * 1024 * 1024) } });
    await expect(downloadToFile("https://cdn.example.com/a.mp3", path, {
      maxBytes: 500 * 1024 * 1024, allowPrivateNetwork: true, fetchImpl: fetchReturning(response)
    })).rejects.toThrow("600 MB, above the 500 MB limit");
  });

  it("stops a stream that grows past the limit", async () => {
    const path = await target();
    const error = await downloadToFile("https://cdn.example.com/a.mp3", path, {
      maxBytes: 4, allowPrivateNetwork: true, fetchImpl: fetchReturning(new Response(streamOf(["abc", "def"])))
    }).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(PermanentError);
  });

  it("treats a missing file as permanent and a server error as temporary", async () => {
    const options = { maxBytes: 10, allowPrivateNetwork: true };
    const missing = await downloadToFile("https://cdn.example.com/a.mp3", await target(), {
      ...options, fetchImpl: fetchReturning(new Response("", { status: 404 }))
    }).catch((caught: unknown) => caught);
    expect(missing).toBeInstanceOf(PermanentError);

    const unavailable = await downloadToFile("https://cdn.example.com/a.mp3", await target(), {
      ...options, fetchImpl: fetchReturning(new Response("", { status: 503 }))
    }).catch((caught: unknown) => caught);
    expect(unavailable).toBeInstanceOf(Error);
    expect(unavailable).not.toBeInstanceOf(PermanentError);
  });
});
