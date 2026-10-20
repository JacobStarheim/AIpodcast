import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import {
  assertLoopbackUrl, demoGuid, demoSourceName, demoTitle, escapeXml, prepareDemoFixture
} from "./demo-fixture.mjs";

const configuredOrigin = process.env.DEMO_BASE_URL
  ? assertLoopbackUrl(process.env.DEMO_BASE_URL, "DEMO_BASE_URL")
  : undefined;
const configuredUrl = configuredOrigin ? new URL(configuredOrigin) : undefined;
const port = Number(process.env.DEMO_PORT || configuredUrl?.port ||
  (configuredUrl ? 80 : 4100));
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("DEMO_PORT must be an integer between 1 and 65535.");
}
if (configuredUrl && Number(configuredUrl.port || 80) !== port) {
  throw new Error("DEMO_BASE_URL must use the same port as DEMO_PORT.");
}
if (configuredUrl?.hostname === "[::1]") {
  throw new Error("DEMO_BASE_URL must use 127.0.0.1 or localhost; the demo server binds IPv4 loopback.");
}
const origin = assertLoopbackUrl(
  configuredOrigin || `http://127.0.0.1:${port}`, "DEMO_BASE_URL"
);
const fixture = await prepareDemoFixture();
const episodeSize = (await stat(fixture.episodePath)).size;
const feed = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>${escapeXml(demoSourceName)}</title>
    <link>${escapeXml(origin)}</link>
    <description>A local generated episode for live integration testing.</description>
    <language>en</language>
    <item>
      <guid isPermaLink="false">${demoGuid}</guid>
      <title>${escapeXml(demoTitle)}</title>
      <description>A short fictional research voyage for testing audio and grounded questions.</description>
      <pubDate>Tue, 20 Oct 2026 12:00:00 GMT</pubDate>
      <enclosure url="${escapeXml(origin)}/aurora.mp3" length="${episodeSize}" type="audio/mpeg"/>
      <itunes:duration>${Math.round(fixture.durationSec)}</itunes:duration>
    </item>
  </channel>
</rss>`;

function sendText(req, res, status, contentType, body) {
  res.writeHead(status, {
    "Content-Type": contentType,
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store"
  });
  res.end(req.method === "HEAD" ? undefined : body);
}

const server = createServer((req, res) => {
  if (!["GET", "HEAD"].includes(req.method)) {
    res.writeHead(405, { Allow: "GET, HEAD" });
    res.end();
    return;
  }
  const path = new URL(req.url, origin).pathname;
  if (path === "/health") {
    sendText(req, res, 200, "application/json", JSON.stringify({
      ok: true, guid: demoGuid, durationSec: fixture.durationSec
    }));
    return;
  }
  if (path === "/feed.xml") {
    sendText(req, res, 200, "application/rss+xml; charset=utf-8", feed);
    return;
  }
  if (path !== "/aurora.mp3") {
    sendText(req, res, 404, "text/plain; charset=utf-8", "Not found\n");
    return;
  }

  let start = 0;
  let end = episodeSize - 1;
  if (req.headers.range) {
    const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
    if (!range || (!range[1] && !range[2])) {
      res.writeHead(416, { "Content-Range": `bytes */${episodeSize}` });
      res.end();
      return;
    }
    if (!range[1]) {
      const suffixLength = Number(range[2]);
      start = Math.max(0, episodeSize - suffixLength);
    } else {
      start = Number(range[1]);
      if (range[2]) end = Math.min(Number(range[2]), episodeSize - 1);
    }
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
        start < 0 || start > end || start >= episodeSize) {
      res.writeHead(416, { "Content-Range": `bytes */${episodeSize}` });
      res.end();
      return;
    }
  }
  const headers = {
    "Content-Type": "audio/mpeg",
    "Content-Length": end - start + 1,
    "Accept-Ranges": "bytes",
    "Cache-Control": "no-store"
  };
  if (req.headers.range) headers["Content-Range"] = `bytes ${start}-${end}/${episodeSize}`;
  res.writeHead(req.headers.range ? 206 : 200, headers);
  if (req.method === "HEAD") {
    res.end();
    return;
  }
  const stream = createReadStream(fixture.episodePath, { start, end });
  stream.on("error", () => res.destroy());
  res.on("close", () => stream.destroy());
  stream.pipe(res);
});
server.on("error", (error) => {
  console.error(`Demo server failed: ${error.message}`);
  process.exitCode = 1;
});
server.listen(port, "127.0.0.1", () => {
  console.log(`Demo RSS: ${origin}/feed.xml`);
  console.log(`Demo audio: ${origin}/aurora.mp3 (${fixture.durationSec.toFixed(1)} seconds)`);
  console.log(`Android emulator: adb reverse tcp:${port} tcp:${port}`);
  console.log("Keep this process running while ingesting and playing the demo episode.");
});
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    server.close();
    server.closeAllConnections();
  });
}
