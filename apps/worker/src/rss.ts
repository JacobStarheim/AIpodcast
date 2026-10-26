import { XMLParser } from "fast-xml-parser";

export interface ParsedRssEpisode {
  guid: string;
  title: string;
  description: string;
  publishedAt: string;
  audioUrl: string;
  imageUrl: string | null;
  durationSec: number | null;
}

export interface ParsedFeed {
  title: string;
  language: string | null;
  imageUrl: string | null;
  episodes: ParsedRssEpisode[];
}

function asArray<T>(value: T | T[] | undefined): T[] {
  if (!value) {
    return [];
  }
  return Array.isArray(value) ? value : [value];
}

function readText(value: unknown): string {
  if (typeof value === "string") {
    return value.trim();
  }

  if (value && typeof value === "object" && "#text" in value) {
    const maybeText = (value as Record<string, unknown>)["#text"];
    return typeof maybeText === "string" ? maybeText.trim() : "";
  }

  return "";
}

function parseDuration(value: unknown): number | null {
  const raw = readText(value);
  if (!raw) {
    return null;
  }

  if (/^\d+$/.test(raw)) {
    return Number(raw);
  }

  const parts = raw.split(":").map((part) => Number(part));
  if (parts.some((part) => Number.isNaN(part))) {
    return null;
  }

  if (parts.length === 3) {
    const [hours = 0, minutes = 0, seconds = 0] = parts;
    return hours * 3600 + minutes * 60 + seconds;
  }

  if (parts.length === 2) {
    const [minutes = 0, seconds = 0] = parts;
    return minutes * 60 + seconds;
  }

  return null;
}

function parsePublishedAt(value: unknown): string {
  const text = readText(value);
  const date = text ? new Date(text) : new Date();
  return Number.isNaN(date.getTime()) ? new Date().toISOString() : date.toISOString();
}

function getEnclosureUrl(item: Record<string, unknown>): string {
  const enclosure = item.enclosure as Record<string, unknown> | undefined;
  if (enclosure && typeof enclosure.url === "string") {
    return enclosure.url;
  }

  const mediaContent = item["media:content"] as Record<string, unknown> | undefined;
  if (mediaContent && typeof mediaContent.url === "string") {
    return mediaContent.url;
  }

  return "";
}

function getImageUrl(node: Record<string, unknown> | undefined): string | null {
  const itunesImage = node?.["itunes:image"] as Record<string, unknown> | undefined;
  if (itunesImage && typeof itunesImage.href === "string" && /^https?:\/\//.test(itunesImage.href)) {
    return itunesImage.href;
  }
  const image = node?.image as Record<string, unknown> | undefined;
  const url = image ? readText(image.url) : "";
  return /^https?:\/\//.test(url) ? url : null;
}

export function parseRss(xml: string): ParsedRssEpisode[] {
  return parseFeed(xml).episodes;
}

export function parseFeed(xml: string): ParsedFeed {
  const parser = new XMLParser({
    ignoreAttributes: false,
    attributeNamePrefix: "",
    trimValues: true,
    parseTagValue: false
  });

  const parsed = parser.parse(xml) as Record<string, unknown>;
  const channel = (parsed.rss as Record<string, unknown> | undefined)?.channel as
    | Record<string, unknown>
    | undefined;

  const items = channel ? asArray(channel.item as Record<string, unknown> | Record<string, unknown>[]) : [];

  const byGuid = new Map<string, ParsedRssEpisode>();

  for (const item of items) {
    const guid = readText(item.guid) || readText(item.link) || readText(item.title);
    const title = readText(item.title) || "Untitled episode";
    const description = readText(item.description) || readText(item["content:encoded"]);
    const audioUrl = getEnclosureUrl(item);

    if (!guid || !audioUrl || byGuid.has(guid)) {
      continue;
    }

    byGuid.set(guid, {
      guid,
      title,
      description,
      publishedAt: parsePublishedAt(item.pubDate),
      audioUrl,
      imageUrl: getImageUrl(item),
      durationSec: parseDuration(item["itunes:duration"])
    });
  }

  const episodes = [...byGuid.values()].sort((a, b) => {
    return new Date(b.publishedAt).getTime() - new Date(a.publishedAt).getTime();
  });
  const language = channel ? readText(channel.language).split(/[\s,;]/)[0] ?? "" : "";
  return {
    title: channel ? readText(channel.title) : "",
    language: /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(language) ? language : null,
    imageUrl: getImageUrl(channel),
    episodes
  };
}
