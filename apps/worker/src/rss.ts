import { XMLParser } from "fast-xml-parser";

export interface ParsedRssEpisode {
  guid: string;
  title: string;
  description: string;
  publishedAt: string;
  audioUrl: string;
  durationSec: number | null;
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

export function parseRss(xml: string): ParsedRssEpisode[] {
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
      durationSec: parseDuration(item["itunes:duration"])
    });
  }

  return [...byGuid.values()].sort((a, b) => {
    return new Date(b.publishedAt).getTime() - new Date(a.publishedAt).getTime();
  });
}
