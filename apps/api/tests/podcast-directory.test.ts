import { describe, expect, it, vi } from "vitest";
import { ItunesPodcastDirectory } from "../src/podcast-directory.js";

describe("ItunesPodcastDirectory", () => {
  it("returns podcasts with feeds and caches repeated searches", async () => {
    const fetchImpl = vi.fn(async (_url: URL) => new Response(JSON.stringify({
      results: [
        { collectionName: "Hard Fork", artistName: "NYT", feedUrl: "https://feeds.example.com/hf",
          artworkUrl600: "https://img.example.com/600.jpg", primaryGenreName: "Technology" },
        { collectionName: "No feed", artistName: "Someone" },
        { collectionName: "Bad feed", feedUrl: "javascript:alert(1)" }
      ]
    })));
    let now = 0;
    const directory = new ItunesPodcastDirectory(fetchImpl as unknown as typeof fetch, () => now);

    const results = await directory.search("hard fork", "NO");
    expect(results).toEqual([{
      title: "Hard Fork", author: "NYT", feedUrl: "https://feeds.example.com/hf",
      imageUrl: "https://img.example.com/600.jpg", genre: "Technology"
    }]);
    const url = fetchImpl.mock.calls[0]![0];
    expect(url.hostname).toBe("itunes.apple.com");
    expect(url.searchParams.get("term")).toBe("hard fork");
    expect(url.searchParams.get("country")).toBe("NO");
    expect(url.searchParams.get("media")).toBe("podcast");

    await directory.search("Hard Fork", "NO");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    now = 11 * 60_000;
    await directory.search("hard fork", "NO");
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("reports a failed directory response", async () => {
    const directory = new ItunesPodcastDirectory((async () => new Response("", { status: 503 })) as unknown as typeof fetch);
    await expect(directory.search("news", "US")).rejects.toThrow("HTTP 503");
  });
});
