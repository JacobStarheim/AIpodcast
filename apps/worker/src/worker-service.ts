import type { Pool } from "pg";
import { chunkTranscriptSegments } from "./chunking.js";
import { WorkerOpenAiClient } from "./openai-client.js";
import { parseRss } from "./rss.js";

interface WorkerServiceOptions {
  maxEpisodeAudioMb: number;
  defaultMaxEpisodesPerSource: number;
}

interface SourceRow {
  id: string;
  name: string;
  rss_url: string;
}

interface EpisodeRow {
  id: string;
  title: string;
  audio_url: string;
}

interface JobRow {
  id: string;
  source_id: string | null;
  max_episodes_per_source: number | null;
}

export class WorkerService {
  constructor(
    private readonly pool: Pool,
    private readonly aiClient: WorkerOpenAiClient,
    private readonly options: WorkerServiceOptions
  ) {}

  async pollOnce(): Promise<void> {
    const jobs = await this.pool.query<JobRow>(
      `SELECT id, source_id, max_episodes_per_source
       FROM ingest_jobs
       WHERE status = 'queued'
       ORDER BY created_at ASC
       LIMIT 5`
    );

    for (const queuedJob of jobs.rows) {
      await this.processJob(queuedJob);
    }
  }

  private async processJob(job: JobRow): Promise<void> {
    const claimResult = await this.pool.query<JobRow>(
      `UPDATE ingest_jobs
       SET status = 'processing', error = NULL
       WHERE id = $1 AND status = 'queued'
       RETURNING id, source_id, max_episodes_per_source`,
      [job.id]
    );

    if (claimResult.rowCount === 0) {
      return;
    }

    const claimedJob = claimResult.rows[0];

    try {
      const sourceRows = claimedJob.source_id
        ? await this.pool.query<SourceRow>(
            `SELECT id, name, rss_url
             FROM rss_sources
             WHERE id = $1 AND active = TRUE`,
            [claimedJob.source_id]
          )
        : await this.pool.query<SourceRow>(
            `SELECT id, name, rss_url
             FROM rss_sources
             WHERE active = TRUE
             ORDER BY created_at ASC`
          );

      for (const source of sourceRows.rows) {
        const maxEpisodesPerSource =
          claimedJob.max_episodes_per_source ?? this.options.defaultMaxEpisodesPerSource;
        await this.processSource(source, maxEpisodesPerSource);
      }

      await this.pool.query(`UPDATE ingest_jobs SET status = 'completed' WHERE id = $1`, [claimedJob.id]);
    } catch (error) {
      const message = error instanceof Error ? error.message.slice(0, 2_000) : "unknown_error";
      await this.pool.query(`UPDATE ingest_jobs SET status = 'failed', error = $2 WHERE id = $1`, [
        claimedJob.id,
        message
      ]);
    }
  }

  private async processSource(source: SourceRow, maxEpisodesPerSource: number): Promise<void> {
    const feedResponse = await fetch(source.rss_url);
    if (!feedResponse.ok) {
      throw new Error(`Failed to fetch RSS feed (${source.rss_url}): ${feedResponse.status}`);
    }

    const xml = await feedResponse.text();
    const feedEpisodes = parseRss(xml);

    for (const feedEpisode of feedEpisodes) {
      await this.pool.query(
        `INSERT INTO episodes (
          source_id,
          guid,
          title,
          description,
          published_at,
          audio_url,
          duration_sec,
          transcription_status
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending')
        ON CONFLICT (guid, source_id)
        DO UPDATE SET
          title = EXCLUDED.title,
          description = EXCLUDED.description,
          published_at = EXCLUDED.published_at,
          audio_url = EXCLUDED.audio_url,
          duration_sec = EXCLUDED.duration_sec,
          updated_at = NOW()`,
        [
          source.id,
          feedEpisode.guid,
          feedEpisode.title,
          feedEpisode.description,
          feedEpisode.publishedAt,
          feedEpisode.audioUrl,
          feedEpisode.durationSec
        ]
      );
    }

    const pendingEpisodes = await this.pool.query<EpisodeRow>(
      `SELECT id, title, audio_url
       FROM episodes
       WHERE source_id = $1
         AND transcription_status = 'pending'
       ORDER BY published_at DESC
       LIMIT $2`,
      [source.id, maxEpisodesPerSource]
    );

    for (const episode of pendingEpisodes.rows) {
      await this.transcribeEpisode(episode);
    }
  }

  private async transcribeEpisode(episode: EpisodeRow): Promise<void> {
    try {
      const audio = await this.downloadEpisodeAudio(episode.audio_url);

      const transcription = await this.aiClient.transcribeEpisodeAudio({
        buffer: audio.buffer,
        filename: `episode-${episode.id}.mp3`,
        mimeType: audio.mimeType
      });

      const chunks = chunkTranscriptSegments(transcription.segments);

      const client = await this.pool.connect();
      try {
        await client.query("BEGIN");
        await client.query(`DELETE FROM transcript_segments WHERE episode_id = $1`, [episode.id]);

        for (const chunk of chunks) {
          const embedding = await this.aiClient.embedText(chunk.text);
          const embeddingLiteral = embedding.length > 0 ? `[${embedding.join(",")}]` : null;

          await client.query(
            `INSERT INTO transcript_segments (
              episode_id,
              start_sec,
              end_sec,
              speaker,
              text,
              embedding
            )
            VALUES ($1, $2, $3, $4, $5, $6::vector)`,
            [
              episode.id,
              chunk.startSec,
              chunk.endSec,
              chunk.speaker,
              chunk.text,
              embeddingLiteral
            ]
          );
        }

        await client.query(
          `UPDATE episodes
           SET transcription_status = 'ready', duration_sec = COALESCE(duration_sec, $2)
           WHERE id = $1`,
          [episode.id, Math.round(transcription.durationSec)]
        );

        await client.query("COMMIT");
      } catch (error) {
        await client.query("ROLLBACK");
        throw error;
      } finally {
        client.release();
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown_error";
      await this.pool.query(
        `UPDATE episodes
         SET transcription_status = 'failed',
             description = CONCAT(description, '\n\n[Transcription failed: ', $2, ']')
         WHERE id = $1`,
        [episode.id, message.slice(0, 500)]
      );
    }
  }

  private async downloadEpisodeAudio(audioUrl: string): Promise<{ buffer: Buffer; mimeType: string }> {
    const response = await fetch(audioUrl);
    if (!response.ok) {
      throw new Error(`Failed to download episode audio: ${response.status}`);
    }

    const contentLengthHeader = response.headers.get("content-length");
    const contentLength = contentLengthHeader ? Number(contentLengthHeader) : null;
    const maxBytes = this.options.maxEpisodeAudioMb * 1024 * 1024;

    if (contentLength && contentLength > maxBytes) {
      throw new Error(`Episode audio too large (${contentLength} bytes)`);
    }

    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > maxBytes) {
      throw new Error(`Episode audio exceeded size limit (${buffer.length} bytes)`);
    }

    const mimeType = response.headers.get("content-type")?.split(";")[0] ?? "audio/mpeg";
    return { buffer, mimeType };
  }
}
