import type { PodcastSearchResult } from "@podcast/shared-types";
import type { PodcastDirectory } from "./types.js";

interface ItunesResult {
  collectionName?: unknown;
  artistName?: unknown;
  feedUrl?: unknown;
  artworkUrl600?: unknown;
  artworkUrl100?: unknown;
  primaryGenreName?: unknown;
}

function httpUrl(value: unknown): string | null {
  return typeof value === "string" && /^https?:\/\//i.test(value) ? value : null;
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

/** The public Apple Podcasts search API. It needs no key and returns RSS feed URLs. */
export class ItunesPodcastDirectory implements PodcastDirectory {
  private readonly cache = new Map<string, { expiresAt: number; results: PodcastSearchResult[] }>();

  constructor(
    private readonly fetchImpl: typeof fetch = fetch,
    private readonly now: () => number = Date.now
  ) {}

  async search(term: string, country: string): Promise<PodcastSearchResult[]> {
    const key = `${country}:${term.toLocaleLowerCase()}`;
    const cached = this.cache.get(key);
    if (cached && cached.expiresAt > this.now()) return cached.results;

    const url = new URL("https://itunes.apple.com/search");
    url.search = new URLSearchParams({
      media: "podcast",
      entity: "podcast",
      limit: "15",
      country,
      term
    }).toString();
    const response = await this.fetchImpl(url, { signal: AbortSignal.timeout(8_000) });
    if (!response.ok) {
      throw new Error(`Podcast directory search failed: HTTP ${response.status}`);
    }
    const body = (await response.json()) as { results?: ItunesResult[] };
    const results = (body.results ?? []).flatMap((item): PodcastSearchResult[] => {
      const feedUrl = httpUrl(item.feedUrl);
      const title = text(item.collectionName);
      if (!feedUrl || !title) return [];
      return [{
        title,
        author: text(item.artistName),
        feedUrl,
        imageUrl: httpUrl(item.artworkUrl600) ?? httpUrl(item.artworkUrl100),
        genre: text(item.primaryGenreName)
      }];
    });

    if (this.cache.size >= 200) this.cache.clear();
    this.cache.set(key, { expiresAt: this.now() + 10 * 60_000, results });
    return results;
  }
}
