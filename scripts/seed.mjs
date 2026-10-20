import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";
import pg from "pg";

const config = dotenv.parse(readFileSync(fileURLToPath(new URL("../apps/api/.env", import.meta.url))));
const adminKey = process.env.ADMIN_KEY || config.ADMIN_KEY;
const apiOrigin = process.env.API_BASE_URL || "http://localhost:4000";
const rssUrl = process.env.RSS_URL || "https://feeds.simplecast.com/54nAGcIl";
const name = process.env.SOURCE_NAME || "Podcast source";
const maxEpisodes = Number(process.env.MAX_EPISODES || "1");
if (!adminKey || !Number.isInteger(maxEpisodes) || maxEpisodes < 1 || maxEpisodes > 100) {
  throw new Error("Set ADMIN_KEY in apps/api/.env and MAX_EPISODES to an integer between 1 and 100.");
}
for (const url of [apiOrigin, rssUrl]) {
  if (!["http:", "https:"].includes(new URL(url).protocol)) {
    throw new Error("API_BASE_URL and RSS_URL must use HTTP or HTTPS.");
  }
}

async function post(path, body) {
  const response = await fetch(new URL(path, apiOrigin), {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-admin-key": adminKey },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`${path} failed (HTTP ${response.status}).`);
  return response.json();
}

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL || config.DATABASE_URL,
  connectionTimeoutMillis: 10_000,
});
try {
  const existing = await pool.query(
    "SELECT id FROM rss_sources WHERE rss_url = $1 AND active = TRUE ORDER BY created_at LIMIT 1",
    [rssUrl],
  );
  const source = existing.rows[0] || await post("/v1/admin/sources", { name, rssUrl });
  if (!source.id) throw new Error("The API did not return a source ID.");
  const job = await post("/v1/admin/ingest/run", { sourceId: source.id, maxEpisodesPerSource: maxEpisodes });
  console.log(`Queued job ${job.jobId} for source ${source.id}, up to ${maxEpisodes} episode(s).`);
} finally {
  await pool.end();
}
