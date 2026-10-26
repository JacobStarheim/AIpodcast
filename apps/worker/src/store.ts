import type { TranscriptionStatus } from "@podcast/shared-types";
import type { Pool, PoolClient } from "pg";
import type { ParsedFeed, ParsedRssEpisode } from "./rss.js";
import type { TimedText } from "./summarize.js";

export interface ClaimedJob {
  id: string;
  sourceId: string | null;
  episodeId: string | null;
  maxEpisodesPerSource: number | null;
}

export interface SourceRecord {
  id: string;
  name: string;
  rssUrl: string;
}

export interface EpisodeRecord {
  id: string;
  sourceId: string;
  title: string;
  audioUrl: string;
  status: TranscriptionStatus;
  durationSec: number | null;
}

export interface SegmentToStore {
  startSec: number;
  endSec: number;
  speaker: string | null;
  text: string;
  contextText: string;
  embedding: number[];
}

export interface ChapterToStore {
  title: string;
  summary: string;
  startSec: number;
  endSec: number;
  embedding: number[];
}

/** Everything the worker reads and writes. PostgresWorkerStore is the real one. */
export interface WorkerStore {
  requeueStaleJobs(staleAfterSec: number): Promise<void>;
  claimNextJob(): Promise<ClaimedJob | null>;
  heartbeat(jobId: string, episodeId: string | null): Promise<void>;
  completeJob(jobId: string): Promise<void>;
  failJob(jobId: string, error: string): Promise<void>;

  getActiveSources(sourceId: string | null): Promise<SourceRecord[]>;
  saveFeed(sourceId: string, feed: ParsedFeed): Promise<void>;

  getEpisode(episodeId: string): Promise<EpisodeRecord | null>;
  selectEpisodesToTranscribe(sourceId: string, limit: number, maxAttempts: number): Promise<EpisodeRecord[]>;
  /** Marks the episode processing and counts the attempt; false if it is not waiting. */
  startTranscription(episodeId: string): Promise<boolean>;
  saveTranscript(episodeId: string, durationSec: number, segments: SegmentToStore[]): Promise<void>;
  failTranscription(episodeId: string, error: string, options: { permanent: boolean; maxAttempts: number }): Promise<void>;

  selectEpisodesMissingSummary(sourceId: string, limit: number, maxAttempts: number): Promise<EpisodeRecord[]>;
  getTranscript(episodeId: string): Promise<TimedText[]>;
  saveSummary(
    episodeId: string,
    summary: { language: string | null; summary: string; chapters: ChapterToStore[] }
  ): Promise<void>;
  failSummary(episodeId: string): Promise<void>;
}

function vectorLiteral(embedding: number[]): string {
  return `[${embedding.join(",")}]`;
}

function mapEpisode(row: Record<string, unknown>): EpisodeRecord {
  return {
    id: String(row.id),
    sourceId: String(row.source_id),
    title: String(row.title),
    audioUrl: String(row.audio_url),
    status: String(row.transcription_status) as TranscriptionStatus,
    durationSec: row.duration_sec === null || row.duration_sec === undefined ? null : Number(row.duration_sec)
  };
}

const episodeColumns = "id, source_id, title, audio_url, transcription_status, duration_sec";

export class PostgresWorkerStore implements WorkerStore {
  constructor(private readonly pool: Pool) {}

  private async transaction(work: (client: PoolClient) => Promise<void>): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await work(client);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async requeueStaleJobs(staleAfterSec: number): Promise<void> {
    await this.pool.query(
      `UPDATE ingest_jobs
       SET status = 'queued', error = 'Requeued after the worker processing it stopped responding'
       WHERE status = 'processing'
         AND COALESCE(heartbeat_at, updated_at) < NOW() - make_interval(secs => $1)`,
      [staleAfterSec]
    );
    await this.pool.query(
      `UPDATE episodes SET transcription_status = 'queued'
       WHERE transcription_status = 'processing'
         AND updated_at < NOW() - make_interval(secs => $1)`,
      [staleAfterSec]
    );
  }

  async claimNextJob(): Promise<ClaimedJob | null> {
    // SKIP LOCKED lets several workers poll the same table without double work.
    const result = await this.pool.query(
      `UPDATE ingest_jobs
       SET status = 'processing', error = NULL, heartbeat_at = NOW()
       WHERE id = (
         SELECT id FROM ingest_jobs
         WHERE status = 'queued'
         ORDER BY created_at ASC
         LIMIT 1
         FOR UPDATE SKIP LOCKED
       )
       RETURNING id, source_id, episode_id, max_episodes_per_source`
    );
    const row = result.rows[0];
    if (!row) return null;
    return {
      id: String(row.id),
      sourceId: row.source_id ? String(row.source_id) : null,
      episodeId: row.episode_id ? String(row.episode_id) : null,
      maxEpisodesPerSource: row.max_episodes_per_source === null ? null : Number(row.max_episodes_per_source)
    };
  }

  async heartbeat(jobId: string, episodeId: string | null): Promise<void> {
    await this.pool.query(`UPDATE ingest_jobs SET heartbeat_at = NOW() WHERE id = $1`, [jobId]);
    if (episodeId) {
      // The update trigger refreshes updated_at, which marks the episode as alive.
      await this.pool.query(
        `UPDATE episodes SET transcription_status = transcription_status
         WHERE id = $1 AND transcription_status = 'processing'`,
        [episodeId]
      );
    }
  }

  async completeJob(jobId: string): Promise<void> {
    await this.pool.query(`UPDATE ingest_jobs SET status = 'completed' WHERE id = $1`, [jobId]);
  }

  async failJob(jobId: string, error: string): Promise<void> {
    await this.pool.query(`UPDATE ingest_jobs SET status = 'failed', error = $2 WHERE id = $1`, [
      jobId,
      error.slice(0, 2_000)
    ]);
  }

  async getActiveSources(sourceId: string | null): Promise<SourceRecord[]> {
    const result = sourceId
      ? await this.pool.query(
          `SELECT id, name, rss_url FROM rss_sources WHERE id = $1 AND active = TRUE`,
          [sourceId]
        )
      : await this.pool.query(
          `SELECT id, name, rss_url FROM rss_sources WHERE active = TRUE ORDER BY created_at ASC`
        );
    return result.rows.map((row) => ({ id: String(row.id), name: String(row.name), rssUrl: String(row.rss_url) }));
  }

  async saveFeed(sourceId: string, feed: ParsedFeed): Promise<void> {
    await this.pool.query(
      `UPDATE rss_sources
       SET name = CASE WHEN name = '' AND $2 <> '' THEN $2 ELSE name END,
           image_url = COALESCE(image_url, $3),
           language = COALESCE($4, language)
       WHERE id = $1`,
      [sourceId, feed.title.slice(0, 300), feed.imageUrl, feed.language]
    );
    for (let offset = 0; offset < feed.episodes.length; offset += 500) {
      await this.upsertEpisodes(sourceId, feed.episodes.slice(offset, offset + 500));
    }
  }

  private async upsertEpisodes(sourceId: string, episodes: ParsedRssEpisode[]): Promise<void> {
    if (episodes.length === 0) return;
    await this.pool.query(
      `INSERT INTO episodes (
         source_id, guid, title, description, published_at, audio_url, image_url, duration_sec,
         transcription_status
       )
       SELECT $1, guid, title, description, published_at, audio_url, image_url, duration_sec, 'pending'
       FROM unnest($2::text[], $3::text[], $4::text[], $5::timestamptz[], $6::text[], $7::text[], $8::int[])
         AS feed(guid, title, description, published_at, audio_url, image_url, duration_sec)
       ON CONFLICT (guid, source_id)
       DO UPDATE SET
         title = EXCLUDED.title,
         description = EXCLUDED.description,
         published_at = EXCLUDED.published_at,
         audio_url = EXCLUDED.audio_url,
         image_url = COALESCE(EXCLUDED.image_url, episodes.image_url),
         duration_sec = COALESCE(EXCLUDED.duration_sec, episodes.duration_sec)`,
      [
        sourceId,
        episodes.map((episode) => episode.guid),
        episodes.map((episode) => episode.title),
        episodes.map((episode) => episode.description),
        episodes.map((episode) => episode.publishedAt),
        episodes.map((episode) => episode.audioUrl),
        episodes.map((episode) => episode.imageUrl),
        episodes.map((episode) => (episode.durationSec === null ? null : Math.round(episode.durationSec)))
      ]
    );
  }

  async getEpisode(episodeId: string): Promise<EpisodeRecord | null> {
    const result = await this.pool.query(`SELECT ${episodeColumns} FROM episodes WHERE id = $1`, [episodeId]);
    return result.rows[0] ? mapEpisode(result.rows[0]) : null;
  }

  async selectEpisodesToTranscribe(sourceId: string, limit: number, maxAttempts: number): Promise<EpisodeRecord[]> {
    if (limit <= 0) return [];
    const result = await this.pool.query(
      `SELECT ${episodeColumns}
       FROM episodes
       WHERE source_id = $1
         AND transcription_status IN ('pending', 'queued', 'failed')
         AND transcription_attempts < $3
       ORDER BY published_at DESC, id DESC
       LIMIT $2`,
      [sourceId, limit, maxAttempts]
    );
    return result.rows.map(mapEpisode);
  }

  async startTranscription(episodeId: string): Promise<boolean> {
    const result = await this.pool.query(
      `UPDATE episodes
       SET transcription_status = 'processing',
           transcription_attempts = transcription_attempts + 1,
           transcription_error = NULL
       WHERE id = $1 AND transcription_status IN ('pending', 'queued', 'failed')
       RETURNING id`,
      [episodeId]
    );
    return (result.rowCount ?? 0) > 0;
  }

  async saveTranscript(episodeId: string, durationSec: number, segments: SegmentToStore[]): Promise<void> {
    await this.transaction(async (client) => {
      await client.query(`DELETE FROM transcript_segments WHERE episode_id = $1`, [episodeId]);
      await client.query(`DELETE FROM episode_chapters WHERE episode_id = $1`, [episodeId]);
      for (let offset = 0; offset < segments.length; offset += 200) {
        const batch = segments.slice(offset, offset + 200);
        await client.query(
          `INSERT INTO transcript_segments (episode_id, start_sec, end_sec, speaker, text, context_text, embedding)
           SELECT $1, start_sec, end_sec, speaker, text, context_text, embedding::vector
           FROM unnest($2::float8[], $3::float8[], $4::text[], $5::text[], $6::text[], $7::text[])
             AS segment(start_sec, end_sec, speaker, text, context_text, embedding)`,
          [
            episodeId,
            batch.map((segment) => segment.startSec),
            batch.map((segment) => segment.endSec),
            batch.map((segment) => segment.speaker),
            batch.map((segment) => segment.text),
            batch.map((segment) => segment.contextText),
            batch.map((segment) => vectorLiteral(segment.embedding))
          ]
        );
      }
      await client.query(
        `UPDATE episodes
         SET transcription_status = 'ready',
             transcription_error = NULL,
             duration_sec = COALESCE(duration_sec, $2),
             summary = NULL,
             summary_attempts = 0
         WHERE id = $1`,
        [episodeId, Math.round(durationSec)]
      );
    });
  }

  async failTranscription(
    episodeId: string,
    error: string,
    options: { permanent: boolean; maxAttempts: number }
  ): Promise<void> {
    await this.pool.query(
      `UPDATE episodes
       SET transcription_status = 'failed',
           transcription_error = $2,
           transcription_attempts = CASE WHEN $3 THEN GREATEST(transcription_attempts, $4)
                                         ELSE transcription_attempts END
       WHERE id = $1`,
      [episodeId, error.slice(0, 500), options.permanent, options.maxAttempts]
    );
  }

  async selectEpisodesMissingSummary(sourceId: string, limit: number, maxAttempts: number): Promise<EpisodeRecord[]> {
    const result = await this.pool.query(
      `SELECT ${episodeColumns}
       FROM episodes
       WHERE source_id = $1 AND transcription_status = 'ready'
         AND summary IS NULL AND summary_attempts < $3
       ORDER BY published_at DESC, id DESC
       LIMIT $2`,
      [sourceId, limit, maxAttempts]
    );
    return result.rows.map(mapEpisode);
  }

  async getTranscript(episodeId: string): Promise<TimedText[]> {
    const result = await this.pool.query(
      `SELECT start_sec, end_sec, text FROM transcript_segments WHERE episode_id = $1 ORDER BY start_sec`,
      [episodeId]
    );
    return result.rows.map((row) => ({
      startSec: Number(row.start_sec),
      endSec: Number(row.end_sec),
      text: String(row.text)
    }));
  }

  async saveSummary(
    episodeId: string,
    summary: { language: string | null; summary: string; chapters: ChapterToStore[] }
  ): Promise<void> {
    await this.transaction(async (client) => {
      await client.query(`DELETE FROM episode_chapters WHERE episode_id = $1`, [episodeId]);
      await client.query(
        `INSERT INTO episode_chapters (episode_id, position, start_sec, end_sec, title, summary, embedding)
         SELECT $1, position, start_sec, end_sec, title, summary, embedding::vector
         FROM unnest($2::int[], $3::float8[], $4::float8[], $5::text[], $6::text[], $7::text[])
           AS chapter(position, start_sec, end_sec, title, summary, embedding)`,
        [
          episodeId,
          summary.chapters.map((_chapter, index) => index),
          summary.chapters.map((chapter) => chapter.startSec),
          summary.chapters.map((chapter) => chapter.endSec),
          summary.chapters.map((chapter) => chapter.title),
          summary.chapters.map((chapter) => chapter.summary),
          summary.chapters.map((chapter) => vectorLiteral(chapter.embedding))
        ]
      );
      await client.query(
        `UPDATE episodes
         SET summary = $2, language = COALESCE($3, language), summary_attempts = summary_attempts + 1
         WHERE id = $1`,
        [episodeId, summary.summary, summary.language]
      );
    });
  }

  async failSummary(episodeId: string): Promise<void> {
    await this.pool.query(`UPDATE episodes SET summary_attempts = summary_attempts + 1 WHERE id = $1`, [episodeId]);
  }
}
