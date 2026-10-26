import { lookup } from "node:dns/promises";
import { BlockList, isIP } from "node:net";
import { PermanentError } from "./errors.js";

export type LookupAll = (hostname: string) => Promise<{ address: string; family: number }[]>;

export interface NetworkGuardOptions {
  /** Allow loopback and private addresses, e.g. the local demo feed. */
  allowPrivateNetwork: boolean;
  lookupAll?: LookupAll;
}

const blocked = new BlockList();
for (const [network, prefix] of [
  ["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8],
  ["169.254.0.0", 16], ["172.16.0.0", 12], ["192.0.0.0", 24], ["192.168.0.0", 16],
  ["198.18.0.0", 15], ["224.0.0.0", 3]
] as const) {
  blocked.addSubnet(network, prefix, "ipv4");
}
for (const [network, prefix] of [
  ["::", 128], ["::1", 128], ["fc00::", 7], ["fe80::", 10], ["ff00::", 8]
] as const) {
  blocked.addSubnet(network, prefix, "ipv6");
}

export function isPrivateAddress(address: string): boolean {
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(address);
  if (mapped?.[1]) return blocked.check(mapped[1], "ipv4");
  const family = isIP(address);
  if (family === 0) return true;
  return blocked.check(address, family === 4 ? "ipv4" : "ipv6");
}

const defaultLookupAll: LookupAll = (hostname) => lookup(hostname, { all: true, verbatim: true });

/**
 * Feeds and audio URLs come from users. Refuse anything that is not plain
 * HTTP(S) to a public address, so the worker cannot be used to reach services
 * on its own network.
 */
export async function assertFetchableUrl(rawUrl: string, options: NetworkGuardOptions): Promise<URL> {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new PermanentError(`Invalid URL: ${rawUrl}`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new PermanentError(`Only HTTP and HTTPS URLs are supported: ${url.protocol}`);
  }
  if (options.allowPrivateNetwork) return url;

  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  const addresses = isIP(hostname)
    ? [hostname]
    : (await (options.lookupAll ?? defaultLookupAll)(hostname)).map((entry) => entry.address);
  if (addresses.length === 0 || addresses.some(isPrivateAddress)) {
    throw new PermanentError(`Refusing to fetch a private network address: ${url.hostname}`);
  }
  return url;
}

/**
 * fetch() that checks the URL and every redirect target with assertFetchableUrl.
 * Podcast audio often passes through several tracking redirects (six is common),
 * so the limit matches browsers rather than being strict.
 */
export async function guardedFetch(
  rawUrl: string,
  init: RequestInit,
  options: NetworkGuardOptions & { fetchImpl?: typeof fetch; maxRedirects?: number }
): Promise<Response> {
  const fetchImpl = options.fetchImpl ?? fetch;
  let current = rawUrl;
  for (let redirects = 0; ; redirects += 1) {
    const url = await assertFetchableUrl(current, options);
    const response = await fetchImpl(url.href, { ...init, redirect: "manual" });
    const location = response.headers.get("location");
    if (response.status < 300 || response.status >= 400 || !location) {
      return response;
    }
    await response.body?.cancel();
    if (redirects >= (options.maxRedirects ?? 15)) {
      throw new PermanentError(`Too many redirects for ${rawUrl}`);
    }
    current = new URL(location, url).href;
  }
}
