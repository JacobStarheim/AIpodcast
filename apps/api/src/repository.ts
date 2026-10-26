import type {
  Chapter,
  EpisodeDetail,
  EpisodeListResponse,
  EpisodeSummary,
  IngestJobStatus,
  Source,
  SourceSummary,
  TranscriptionStatus,
  User
} from "@podcast/shared-types";
import type { Pool, PoolClient } from "pg";
import { HttpError } from "./security.js";
import type { IngestJob, LoginUser, Repository, RetrievedSegment } from "./types.js";

interface CursorPayload {
  publishedAt: string;
  id: string;
}

function encodeCursor(payload: CursorPayload): string {
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
}

function decodeCursor(cursor: string): CursorPayload {
  try {
    const value = Buffer.from(cursor, "base64url").toString("utf8");
    const parsed = JSON.parse(value) as Partial<CursorPayload>;
    if (parsed.id && parsed.publishedAt && !Number.isNaN(Date.parse(parsed.publishedAt))) {
      return { id: parsed.id, publishedAt: parsed.publishedAt };
    }
  } catch {
    // Fall through to the client error below.
  }
  throw new HttpError(400, "Invalid cursor");
}

function iso(value: unknown): string {
  return new Date(String(value)).toISOString();
}

function nullableNumber(value: unknown): number | null {
  return value === null || value === undefined ? null : Number(value);
}

function nullableString(value: unknown): string | null {
  return value === null || value === undefined || value === "" ? null : String(value);
}

/** A source added by URL has no name until the worker reads the feed title. */
function displayName(name: unknown, rssUrl: unknown): string {
  if (typeof name === "string" && name.trim()) return name;
  try {
    return new URL(String(rssUrl)).hostname;
  } catch {
    return String(rssUrl);
  }
}

const episodeSelect = `
  SELECT e.id, e.source_id, s.name AS source_name, s.rss_url AS source_rss_url, e.guid, e.title,
         e.description, e.published_at, e.audio_url, COALESCE(e.image_url, s.image_url) AS image_url,
         e.duration_sec, e.transcription_status, e.transcription_error,
         COALESCE(e.language, s.language) AS language, e.summary, e.audio_file IS NOT NULL AS has_audio
  FROM episodes e
  JOIN rss_sources s ON s.id = e.source_id`;

/** Signed URL for a stored audio file; see MediaSigner. */
export type PlaybackUrlFor = (episodeId: string) => string;

function mapEpisodeSummary(row: Record<string, unknown>, playbackUrlFor?: PlaybackUrlFor): EpisodeSummary {
  const status = String(row.transcription_status) as TranscriptionStatus;
  const audioUrl = String(row.audio_url);
  return {
    id: String(row.id),
    sourceId: String(row.source_id),
    sourceName: displayName(row.source_name, row.source_rss_url),
    title: String(row.title),
    description: String(row.description ?? ""),
    publishedAt: iso(row.published_at),
    audioUrl,
    playbackUrl: row.has_audio && playbackUrlFor ? playbackUrlFor(String(row.id)) : audioUrl,
    imageUrl: nullableString(row.image_url),
    durationSec: nullableNumber(row.duration_sec),
    transcriptionStatus: status,
    transcriptionError: status === "failed" ? nullableString(row.transcription_error) : null
  };
}

const segmentColumns = `
  ts.id AS segment_id, ts.episode_id, e.title AS episode_title, ts.start_sec, ts.end_sec, ts.text`;

function mapSegment(row: Record<string, unknown>): RetrievedSegment {
  return {
    segmentId: String(row.segment_id),
    kind: "segment",
    episodeId: String(row.episode_id),
    episodeTitle: String(row.episode_title),
    startSec: Number(row.start_sec),
    endSec: Number(row.end_sec),
    playFromSec: Number(row.start_sec),
    text: String(row.text),
    score: row.score === undefined ? 0 : Number(row.score)
  };
}

const sourceSummarySelect = `
  SELECT s.id, s.name, s.rss_url, s.image_url, s.created_at, s.auto_transcribe, s.last_refreshed_at,
         (SELECT COUNT(*) FROM episodes e WHERE e.source_id = s.id)::int AS episode_count,
         (SELECT COUNT(*) FROM episodes e
          WHERE e.source_id = s.id AND e.transcription_status = 'ready')::int AS ready_count,
         job.status AS job_status, job.error AS job_error, job.updated_at AS job_updated_at
  FROM rss_sources s
  LEFT JOIN LATERAL (
    SELECT status, error, updated_at FROM ingest_jobs
    WHERE source_id = s.id AND episode_id IS NULL
    ORDER BY created_at DESC
    LIMIT 1
  ) job ON TRUE`;

function mapSourceSummary(row: Record<string, unknown>): SourceSummary {
  return {
    id: String(row.id),
    name: displayName(row.name, row.rss_url),
    rssUrl: String(row.rss_url),
    imageUrl: nullableString(row.image_url),
    createdAt: iso(row.created_at),
    autoTranscribe: Boolean(row.auto_transcribe),
    lastRefreshedAt: row.last_refreshed_at ? iso(row.last_refreshed_at) : null,
    episodeCount: Number(row.episode_count),
    readyEpisodeCount: Number(row.ready_count),
    lastJob: row.job_status
      ? {
          status: String(row.job_status) as IngestJobStatus,
          error: nullableString(row.job_error),
          updatedAt: iso(row.job_updated_at)
        }
      : null
  };
}

function vectorLiteral(embedding: number[]): string {
  return `[${embedding.join(",")}]`;
}

function mapUser(row: Record<string, unknown>): User {
  return {
    id: String(row.id),
    email: String(row.email),
    name: String(row.name),
    role: String(row.role) === "admin" ? "admin" : "user"
  };
}

export class PostgresRepository implements Repository {
  constructor(
    private readonly pool: Pool,
    private readonly playbackUrlFor?: PlaybackUrlFor
  ) {}

  private summary(row: Record<string, unknown>): EpisodeSummary {
    return mapEpisodeSummary(row, this.playbackUrlFor);
  }

  async createUser(input: {
    email: string;
    name: string;
    passwordHash: string;
    role: User["role"];
  }): Promise<User> {
    try {
      const result = await this.pool.query(
        `INSERT INTO users (email, name, password_hash, role) VALUES ($1, $2, $3, $4)
         RETURNING id, email, name, role`,
        [input.email, input.name, input.passwordHash, input.role]
      );
      return mapUser(result.rows[0]);
    } catch (error) {
      if (error && typeof error === "object" && "code" in error && error.code === "23505") {
        throw new HttpError(409, "a user with that email already exists");
      }
      throw error;
    }
  }

  async findUserForLogin(email: string): Promise<LoginUser | null> {
    const result = await this.pool.query(
      `SELECT id, email, name, role, password_hash, disabled FROM users WHERE lower(email) = lower($1)`,
      [email]
    );
    const row = result.rows[0];
    return row ? { ...mapUser(row), passwordHash: String(row.password_hash), disabled: Boolean(row.disabled) } : null;
  }

  async createSession(input: { userId: string; tokenHash: string; expiresAt: Date }): Promise<void> {
    await this.pool.query(
      `INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, $3)`,
      [input.tokenHash, input.userId, input.expiresAt]
    );
  }

  async findSessionUser(tokenHash: string): Promise<User | null> {
    // Updating last_used_at at most every five minutes keeps reads cheap.
    const result = await this.pool.query(
      `WITH session AS (
         SELECT s.token_hash, u.id, u.email, u.name, u.role
         FROM sessions s JOIN users u ON u.id = s.user_id
         WHERE s.token_hash = $1 AND s.expires_at > NOW() AND NOT u.disabled
       ), touched AS (
         UPDATE sessions SET last_used_at = NOW()
         WHERE token_hash = (SELECT token_hash FROM session) AND last_used_at < NOW() - INTERVAL '5 minutes'
       )
       SELECT id, email, name, role FROM session`,
      [tokenHash]
    );
    return result.rows[0] ? mapUser(result.rows[0]) : null;
  }

  async deleteSession(tokenHash: string): Promise<void> {
    await this.pool.query(`DELETE FROM sessions WHERE token_hash = $1`, [tokenHash]);
  }

  async getTranscribedSecondsToday(): Promise<number> {
    const result = await this.pool.query(
      `SELECT seconds FROM transcription_usage WHERE day = (NOW() AT TIME ZONE 'UTC')::date`
    );
    return Number(result.rows[0]?.seconds ?? 0);
  }

  async updateSource(sourceId: string, input: { autoTranscribe: boolean }): Promise<SourceSummary | null> {
    // Turning it on counts only episodes found from now on as new.
    const updated = await this.pool.query(
      `UPDATE rss_sources
       SET auto_transcribe = $2,
           auto_transcribe_since = CASE WHEN $2 AND NOT auto_transcribe THEN NOW() ELSE auto_transcribe_since END
       WHERE id = $1 AND active
       RETURNING id`,
      [sourceId, input.autoTranscribe]
    );
    if (updated.rowCount === 0) return null;
    const result = await this.pool.query(`${sourceSummarySelect} WHERE s.id = $1`, [sourceId]);
    return mapSourceSummary(result.rows[0]);
  }

  async retranscribeEpisode(episodeId: string): Promise<{ jobId: string } | null> {
    return this.inTransaction(async (client) => {
      const episode = await client.query(
        `UPDATE episodes SET transcription_status = 'queued', transcription_error = NULL
         WHERE id = $1 AND transcription_status <> 'processing'
         RETURNING source_id`,
        [episodeId]
      );
      const sourceId = episode.rows[0]?.source_id;
      if (!sourceId) return null;
      const job = await client.query(
        `INSERT INTO ingest_jobs (source_id, episode_id, max_episodes_per_source, status)
         VALUES ($1, $2, 1, 'queued') RETURNING id`,
        [sourceId, episodeId]
      );
      return { jobId: String(job.rows[0].id) };
    });
  }

  async getEpisodeAudio(episodeId: string): Promise<{ file: string; mimeType: string } | null> {
    const result = await this.pool.query(
      `SELECT audio_file, audio_mime FROM episodes WHERE id = $1 AND audio_file IS NOT NULL`,
      [episodeId]
    );
    const row = result.rows[0];
    return row ? { file: String(row.audio_file), mimeType: String(row.audio_mime ?? "audio/mpeg") } : null;
  }

  private async inTransaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await work(client);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async createSource(input: { name: string; rssUrl: string }): Promise<Source> {
    const result = await this.pool.query(
      `INSERT INTO rss_sources (name, rss_url)
       VALUES ($1, $2)
       RETURNING id, name, rss_url, image_url, created_at`,
      [input.name, input.rssUrl]
    );

    const row = result.rows[0];
    return {
      id: String(row.id),
      name: String(row.name),
      rssUrl: String(row.rss_url),
      imageUrl: nullableString(row.image_url),
      createdAt: iso(row.created_at)
    };
  }

  async addSource(input: { name: string; rssUrl: string; imageUrl: string | null }): Promise<{
    source: SourceSummary;
    created: boolean;
  }> {
    const { sourceId, created } = await this.inTransaction(async (client) => {
      const inserted = await client.query(
        `INSERT INTO rss_sources (name, rss_url, image_url)
         VALUES ($1, $2, $3)
         ON CONFLICT (rss_url) WHERE active DO NOTHING
         RETURNING id`,
        [input.name, input.rssUrl, input.imageUrl]
      );
      const id = inserted.rows[0]?.id
        ?? (await client.query(`SELECT id FROM rss_sources WHERE rss_url = $1 AND active`, [input.rssUrl]))
          .rows[0]?.id;
      if (!id) throw new Error("Source could not be created");
      // Re-adding a feed refreshes its episode list unless an import is already waiting.
      await client.query(
        `INSERT INTO ingest_jobs (source_id, max_episodes_per_source, status)
         SELECT $1, 0, 'queued'
         WHERE NOT EXISTS (
           SELECT 1 FROM ingest_jobs
           WHERE source_id = $1 AND episode_id IS NULL AND status IN ('queued', 'processing')
         )`,
        [id]
      );
      return { sourceId: String(id), created: inserted.rows.length > 0 };
    });
    const result = await this.pool.query(`${sourceSummarySelect} WHERE s.id = $1`, [sourceId]);
    return { source: mapSourceSummary(result.rows[0]), created };
  }

  async listSources(): Promise<SourceSummary[]> {
    const result = await this.pool.query(`${sourceSummarySelect} WHERE s.active ORDER BY s.created_at DESC`);
    return result.rows.map(mapSourceSummary);
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
      maxEpisodesPerSource: nullableNumber(row.max_episodes_per_source),
      status: String(row.status) as IngestJob["status"],
      createdAt: iso(row.created_at)
    };
  }

  async listEpisodes(input: {
    sourceId?: string;
    q?: string;
    statuses?: TranscriptionStatus[];
    limit: number;
    cursor?: string;
  }): Promise<EpisodeListResponse> {
    const params: unknown[] = [];
    const where: string[] = ["s.active"];

    if (input.sourceId) {
      params.push(input.sourceId);
      where.push(`e.source_id = $${params.length}`);
    }

    if (input.q) {
      params.push(`%${input.q.replace(/[\\%_]/g, (match) => `\\${match}`)}%`);
      where.push(`(e.title ILIKE $${params.length} OR e.description ILIKE $${params.length})`);
    }

    if (input.statuses?.length) {
      params.push(input.statuses);
      where.push(`e.transcription_status = ANY($${params.length}::text[])`);
    }

    if (input.cursor) {
      const decoded = decodeCursor(input.cursor);
      params.push(decoded.publishedAt, decoded.id);
      where.push(`(e.published_at, e.id) < ($${params.length - 1}::timestamptz, $${params.length}::uuid)`);
    }

    params.push(input.limit + 1);

    const result = await this.pool.query(
      `${episodeSelect}
       WHERE ${where.join(" AND ")}
       ORDER BY e.published_at DESC, e.id DESC
       LIMIT $${params.length}`,
      params
    );

    const hasMore = result.rows.length > input.limit;
    const rows = hasMore ? result.rows.slice(0, input.limit) : result.rows;
    const items = rows.map((row) => this.summary(row));

    const nextCursor = hasMore
      ? encodeCursor({
          publishedAt: iso(rows[rows.length - 1]?.published_at),
          id: String(rows[rows.length - 1]?.id)
        })
      : null;

    return { items, nextCursor };
  }

  async getEpisodeById(episodeId: string): Promise<EpisodeDetail | null> {
    const result = await this.pool.query(`${episodeSelect} WHERE e.id = $1`, [episodeId]);
    const row = result.rows[0];
    if (!row) {
      return null;
    }
    const chapters = await this.pool.query(
      `SELECT id, title, summary, start_sec, end_sec
       FROM episode_chapters WHERE episode_id = $1 ORDER BY position`,
      [episodeId]
    );
    return {
      ...this.summary(row),
      guid: String(row.guid),
      language: nullableString(row.language),
      summary: nullableString(row.summary),
      chapters: chapters.rows.map((chapter): Chapter => ({
        id: String(chapter.id),
        title: String(chapter.title),
        summary: String(chapter.summary),
        startSec: Number(chapter.start_sec),
        endSec: Number(chapter.end_sec)
      }))
    };
  }

  async requestTranscription(episodeId: string): Promise<{ episode: EpisodeSummary; jobId: string | null } | null> {
    const jobId = await this.inTransaction(async (client) => {
      const current = await client.query(
        `SELECT id, source_id, transcription_status FROM episodes WHERE id = $1 FOR UPDATE`,
        [episodeId]
      );
      const row = current.rows[0];
      if (!row) return undefined;
      if (["ready", "queued", "processing"].includes(String(row.transcription_status))) return null;
      await client.query(
        `UPDATE episodes SET transcription_status = 'queued', transcription_error = NULL WHERE id = $1`,
        [episodeId]
      );
      const job = await client.query(
        `INSERT INTO ingest_jobs (source_id, episode_id, max_episodes_per_source, status)
         VALUES ($1, $2, 1, 'queued') RETURNING id`,
        [row.source_id, episodeId]
      );
      return String(job.rows[0].id);
    });
    if (jobId === undefined) return null;
    const episode = await this.pool.query(`${episodeSelect} WHERE e.id = $1`, [episodeId]);
    return { episode: this.summary(episode.rows[0]), jobId };
  }

  async listReadyLanguages(): Promise<string[]> {
    const result = await this.pool.query(
      `SELECT COALESCE(e.language, s.language) AS language, COUNT(*) AS episodes
       FROM episodes e JOIN rss_sources s ON s.id = e.source_id
       WHERE e.transcription_status = 'ready' AND COALESCE(e.language, s.language) IS NOT NULL
       GROUP BY 1 ORDER BY 2 DESC, 1 ASC LIMIT 5`
    );
    return result.rows.map((row) => String(row.language));
  }

  async searchSegments(input: {
    embedding: number[];
    episodeId?: string;
    topK: number;
  }): Promise<RetrievedSegment[]> {
    if (input.embedding.length === 0) {
      return [];
    }

    const params: unknown[] = [vectorLiteral(input.embedding)];
    let where = "WHERE ts.embedding IS NOT NULL AND e.transcription_status = 'ready'";
    if (input.episodeId) {
      params.push(input.episodeId);
      where += ` AND ts.episode_id = $${params.length}`;
    }
    params.push(input.topK);

    // With a filter, plain HNSW search can return fewer than topK rows; iterative
    // scans keep searching until enough rows match (pgvector 0.8+).
    const rows = await this.inTransaction(async (client) => {
      await client.query("SET LOCAL hnsw.iterative_scan = relaxed_order");
      await client.query("SET LOCAL hnsw.ef_search = 100");
      const result = await client.query(
        `SELECT ${segmentColumns}, 1 - (ts.embedding <=> $1::vector) AS score
         FROM transcript_segments ts
         JOIN episodes e ON e.id = ts.episode_id
         ${where}
         ORDER BY ts.embedding <=> $1::vector ASC
         LIMIT $${params.length}`,
        params
      );
      return result.rows;
    });
    return rows.map(mapSegment).sort((a, b) => b.score - a.score);
  }

  async searchSegmentsByText(input: {
    terms: string[];
    episodeId?: string;
    topK: number;
  }): Promise<RetrievedSegment[]> {
    if (input.terms.length === 0) return [];
    // Terms are stem prefixes: match any word starting with them.
    const params: unknown[] = [input.terms.map((term) => `${term}:*`).join(" | ")];
    let where = "WHERE ts.search_tsv @@ query AND e.transcription_status = 'ready'";
    if (input.episodeId) {
      params.push(input.episodeId);
      where += ` AND ts.episode_id = $${params.length}`;
    }
    params.push(input.topK);
    const result = await this.pool.query(
      `SELECT ${segmentColumns}
       FROM transcript_segments ts
       JOIN episodes e ON e.id = ts.episode_id,
            to_tsquery('simple', $1) AS query
       ${where}
       ORDER BY ts_rank_cd(ts.search_tsv, query) DESC, ts.start_sec ASC
       LIMIT $${params.length}`,
      params
    );
    return result.rows.map(mapSegment);
  }

  async segmentsBetween(input: {
    episodeId: string;
    fromSec: number;
    toSec: number;
    limit: number;
  }): Promise<RetrievedSegment[]> {
    const result = await this.pool.query(
      `SELECT ${segmentColumns}
       FROM transcript_segments ts
       JOIN episodes e ON e.id = ts.episode_id
       WHERE ts.episode_id = $1 AND ts.end_sec > $2 AND ts.start_sec < $3
       ORDER BY ts.start_sec DESC
       LIMIT $4`,
      [input.episodeId, input.fromSec, input.toSec, input.limit]
    );
    return result.rows.map(mapSegment).reverse();
  }

  async withNeighbours(hits: RetrievedSegment[]): Promise<RetrievedSegment[]> {
    const passages = hits.filter((hit) => hit.kind === "segment");
    if (passages.length === 0) return hits;
    // Passages are contiguous, so neighbours touch the hit's start or end.
    const result = await this.pool.query(
      `SELECT DISTINCT ON (hit.position, ts.start_sec) hit.position, ${segmentColumns}
       FROM unnest($1::uuid[], $2::float8[], $3::float8[]) WITH ORDINALITY
              AS hit(episode_id, start_sec, end_sec, position)
       JOIN transcript_segments ts
         ON ts.episode_id = hit.episode_id
        AND ts.end_sec >= hit.start_sec - 0.5
        AND ts.start_sec <= hit.end_sec + 0.5
       JOIN episodes e ON e.id = ts.episode_id
       ORDER BY hit.position, ts.start_sec`,
      [
        passages.map((hit) => hit.episodeId),
        passages.map((hit) => hit.startSec),
        passages.map((hit) => hit.endSec)
      ]
    );
    const scores = new Map(passages.map((hit) => [hit.segmentId, hit.score]));
    const seen = new Set<string>();
    const expanded: RetrievedSegment[] = [];
    for (const row of result.rows) {
      const segment = mapSegment(row);
      if (seen.has(segment.segmentId)) continue;
      seen.add(segment.segmentId);
      expanded.push({ ...segment, score: scores.get(segment.segmentId) ?? 0 });
    }
    return expanded;
  }

  async searchChapters(input: { embedding: number[]; topK: number }): Promise<RetrievedSegment[]> {
    const result = await this.pool.query(
      `SELECT c.id, c.episode_id, e.title AS episode_title, c.start_sec, c.end_sec,
              c.title, c.summary, 1 - (c.embedding <=> $1::vector) AS score
       FROM episode_chapters c
       JOIN episodes e ON e.id = c.episode_id
       WHERE c.embedding IS NOT NULL AND e.transcription_status = 'ready'
       ORDER BY c.embedding <=> $1::vector ASC
       LIMIT $2`,
      [vectorLiteral(input.embedding), input.topK]
    );
    return result.rows.map((row) => ({
      segmentId: `chapter:${String(row.id)}`,
      kind: "chapter" as const,
      episodeId: String(row.episode_id),
      episodeTitle: String(row.episode_title),
      startSec: Number(row.start_sec),
      endSec: Number(row.end_sec),
      playFromSec: Number(row.start_sec),
      text: `${String(row.title)}: ${String(row.summary)}`,
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
