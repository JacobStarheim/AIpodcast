import { describe, expect, it, vi } from "vitest";
import { PermanentError } from "../src/errors.js";
import { assertFetchableUrl, guardedFetch, isPrivateAddress } from "../src/network-guard.js";

const publicLookup = async () => [{ address: "93.184.216.34", family: 4 }];

describe("isPrivateAddress", () => {
  it.each([
    "127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1",
    "0.0.0.0", "::1", "fd00::1", "fe80::1", "::ffff:127.0.0.1", "not-an-ip"
  ])("blocks %s", (address) => {
    expect(isPrivateAddress(address)).toBe(true);
  });

  it.each(["93.184.216.34", "8.8.8.8", "2606:4700::1111"])("allows %s", (address) => {
    expect(isPrivateAddress(address)).toBe(false);
  });
});

describe("assertFetchableUrl", () => {
  it("rejects non-HTTP schemes", async () => {
    await expect(assertFetchableUrl("file:///etc/passwd", { allowPrivateNetwork: true }))
      .rejects.toBeInstanceOf(PermanentError);
  });

  it("rejects hosts that resolve to private addresses", async () => {
    await expect(assertFetchableUrl("http://localhost:4100/feed.xml", {
      allowPrivateNetwork: false,
      lookupAll: async () => [{ address: "127.0.0.1", family: 4 }]
    })).rejects.toThrow("private network");
    await expect(assertFetchableUrl("http://[::1]/feed.xml", { allowPrivateNetwork: false }))
      .rejects.toThrow("private network");
  });

  it("allows public hosts, and private ones only when configured", async () => {
    await expect(assertFetchableUrl("https://feeds.example.com/rss", {
      allowPrivateNetwork: false, lookupAll: publicLookup
    })).resolves.toBeInstanceOf(URL);
    await expect(assertFetchableUrl("http://127.0.0.1:4100/feed.xml", { allowPrivateNetwork: true }))
      .resolves.toBeInstanceOf(URL);
  });
});

describe("guardedFetch", () => {
  it("checks every redirect target", async () => {
    const fetchImpl = vi.fn(async (url: string) => url.startsWith("https://feeds.example.com")
      ? new Response(null, { status: 302, headers: { location: "http://169.254.169.254/latest/meta-data" } })
      : new Response("secret"));
    await expect(guardedFetch("https://feeds.example.com/rss", {}, {
      allowPrivateNetwork: false,
      lookupAll: publicLookup,
      fetchImpl: fetchImpl as unknown as typeof fetch
    })).rejects.toThrow("private network");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("follows allowed redirects", async () => {
    const fetchImpl = vi.fn(async (url: string) => url === "https://a.example.com/rss"
      ? new Response(null, { status: 301, headers: { location: "/moved" } })
      : new Response(`final:${url}`));
    const response = await guardedFetch("https://a.example.com/rss", {}, {
      allowPrivateNetwork: false,
      lookupAll: publicLookup,
      fetchImpl: fetchImpl as unknown as typeof fetch
    });
    expect(await response.text()).toBe("final:https://a.example.com/moved");
  });

  it("follows a typical chain of tracking redirects", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      const hop = Number(new URL(url).pathname.slice(1) || "0");
      return hop < 6
        ? new Response(null, { status: 302, headers: { location: `https://hop${hop + 1}.example.com/${hop + 1}` } })
        : new Response("audio");
    });
    const response = await guardedFetch("https://start.example.com/0", {}, {
      allowPrivateNetwork: false,
      lookupAll: publicLookup,
      fetchImpl: fetchImpl as unknown as typeof fetch
    });
    expect(await response.text()).toBe("audio");
    expect(fetchImpl).toHaveBeenCalledTimes(7);
  });
});
