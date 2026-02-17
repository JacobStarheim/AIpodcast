import type { EpisodeDetail, EpisodeListResponse, EpisodeSummary, Source } from "@podcast/shared-types";
import type { Pool } from "pg";
import type { IngestJob, Repository, RetrievedSegment } from "./types.js";

interface CursorPayload {
  publishedAt: string;
  id: string;
}

function encodeCursor(payload: CursorPayload): string {
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
}

function decodeCursor(cursor: string): CursorPayload {
  const value = Buffer.from(cursor, "base64url").toString("utf8");
  const parsed = JSON.parse(value) as Partial<CursorPayload>;
  if (!parsed.id || !parsed.publishedAt) {
    throw new Error("Invalid cursor");
  }
  return { id: parsed.id, publishedAt: parsed.publishedAt };
}

function mapEpisodeSummary(row: Record<string, unknown>): EpisodeSummary {
  return {
    id: String(row.id),
    sourceId: String(row.source_id),
    sourceName: String(row.source_name),
    title: String(row.title),
    description: String(row.description ?? ""),
    publishedAt: new Date(String(row.published_at)).toISOString(),
    audioUrl: String(row.audio_url),
    transcriptionStatus: String(row.transcription_status) as EpisodeSummary["transcriptionStatus"]
  };
}

export class PostgresRepository implements Repository {
  constructor(private readonly pool: Pool) {}

  async createSource(input: { name: string; rssUrl: string }): Promise<Source> {
    const result = await this.pool.query(
      `INSERT INTO rss_sources (name, rss_url)
       VALUES ($1, $2)
       RETURNING id, name, rss_url, created_at`,
      [input.name, input.rssUrl]
    );

    const row = result.rows[0];
    return {
      id: String(row.id),
      name: String(row.name),
      rssUrl: String(row.rss_url),
      createdAt: new Date(String(row.created_at)).toISOString()
    };
  }

  async enqueueIngestJob(input: {
    sourceId?: string;
    maxEpisodesPerSource?: number;
  }): Promise<IngestJob> {
    const result = await this.pool.query(
      `INSERT INTO ingest_jobs (source_id, max_episodes_per_source, status)
       VALUES ($1, $2, 'queued')
       RETURNING id, source_id, max_episodes_per_source, status, created_at`,
      [input.sourceId ?? null, input.maxEpisodesPerSource ?? null]
    );

    const row = result.rows[0];
    return {
      id: String(row.id),
      sourceId: row.source_id ? String(row.source_id) : null,
      maxEpisodesPerSource: row.max_episodes_per_source ? Number(row.max_episodes_per_source) : null,
      status: String(row.status) as IngestJob["status"],
      createdAt: new Date(String(row.created_at)).toISOString()
    };
  }

  async listEpisodes(input: {
    sourceId?: string;
    q?: string;
    limit: number;
    cursor?: string;
  }): Promise<EpisodeListResponse> {
    const params: unknown[] = [];
    const where: string[] = ["1=1"];

    if (input.sourceId) {
      params.push(input.sourceId);
      where.push(`e.source_id = $${params.length}`);
    }

    if (input.q) {
      params.push(`%${input.q}%`);
      where.push(`(e.title ILIKE $${params.length} OR e.description ILIKE $${params.length})`);
    }

    if (input.cursor) {
      const decoded = decodeCursor(input.cursor);
      params.push(decoded.publishedAt, decoded.id);
      where.push(`(e.published_at, e.id) < ($${params.length - 1}, $${params.length})`);
    }

    params.push(input.limit + 1);

    const result = await this.pool.query(
      `SELECT e.id, e.source_id, s.name AS source_name, e.title, e.description,
              e.published_at, e.audio_url, e.transcription_status
       FROM episodes e
       JOIN rss_sources s ON s.id = e.source_id
       WHERE ${where.join(" AND ")}
       ORDER BY e.published_at DESC, e.id DESC
       LIMIT $${params.length}`,
      params
    );

    const hasMore = result.rows.length > input.limit;
    const rows = hasMore ? result.rows.slice(0, input.limit) : result.rows;
    const items = rows.map(mapEpisodeSummary);

    const nextCursor = hasMore
      ? encodeCursor({
          publishedAt: new Date(String(rows[rows.length - 1]?.published_at)).toISOString(),
          id: String(rows[rows.length - 1]?.id)
        })
      : null;

    return { items, nextCursor };
  }

  async getEpisodeById(episodeId: string): Promise<EpisodeDetail | null> {
    const result = await this.pool.query(
      `SELECT e.id, e.source_id, s.name AS source_name, e.guid, e.title, e.description,
              e.published_at, e.audio_url, e.transcription_status, e.duration_sec
       FROM episodes e
       JOIN rss_sources s ON s.id = e.source_id
       WHERE e.id = $1`,
      [episodeId]
    );

    if (result.rowCount === 0) {
      return null;
    }

    const row = result.rows[0];
    return {
      id: String(row.id),
      sourceId: String(row.source_id),
      sourceName: String(row.source_name),
      guid: String(row.guid),
      title: String(row.title),
      description: String(row.description ?? ""),
      publishedAt: new Date(String(row.published_at)).toISOString(),
      audioUrl: String(row.audio_url),
      transcriptionStatus: String(row.transcription_status) as EpisodeDetail["transcriptionStatus"],
      durationSec: row.duration_sec === null ? null : Number(row.duration_sec)
    };
  }

  async searchSegments(input: {
    embedding: number[];
    episodeId?: string;
    topK: number;
  }): Promise<RetrievedSegment[]> {
    if (input.embedding.length === 0) {
      return [];
    }

    const embeddingLiteral = `[${input.embedding.join(",")}]`;
    const params: unknown[] = [embeddingLiteral];
    let where = "WHERE ts.embedding IS NOT NULL";

    if (input.episodeId) {
      params.push(input.episodeId);
      where += ` AND ts.episode_id = $${params.length}`;
    }

    params.push(input.topK);

    const result = await this.pool.query(
      `SELECT ts.id AS segment_id,
              ts.episode_id,
              e.title AS episode_title,
              ts.start_sec,
              ts.end_sec,
              ts.text,
              1 - (ts.embedding <=> $1::vector) AS score
       FROM transcript_segments ts
       JOIN episodes e ON e.id = ts.episode_id
       ${where}
       ORDER BY ts.embedding <=> $1::vector ASC
       LIMIT $${params.length}`,
      params
    );

    return result.rows.map((row) => ({
      segmentId: String(row.segment_id),
      episodeId: String(row.episode_id),
      episodeTitle: String(row.episode_title),
      startSec: Number(row.start_sec),
      endSec: Number(row.end_sec),
      text: String(row.text),
      score: Number(row.score)
    }));
  }

  async logQaEvent(input: {
    episodeId?: string;
    questionText: string;
    grounded: boolean;
    latencyMs: number;
  }): Promise<void> {
    await this.pool.query(
      `INSERT INTO qa_events (episode_id, question_text, grounded, latency_ms)
       VALUES ($1, $2, $3, $4)`,
      [input.episodeId ?? null, input.questionText, input.grounded, input.latencyMs]
    );
  }
}
