-- Feed metadata used by the library and the add-podcast flow.
ALTER TABLE rss_sources
  ADD COLUMN IF NOT EXISTS image_url TEXT,
  ADD COLUMN IF NOT EXISTS language TEXT;

-- One active source per feed URL, so adding the same podcast twice is harmless.
CREATE UNIQUE INDEX IF NOT EXISTS idx_rss_sources_active_url
  ON rss_sources(rss_url) WHERE active;

-- Episodes can be queued individually and retried a limited number of times.
ALTER TABLE episodes DROP CONSTRAINT IF EXISTS episodes_transcription_status_check;
ALTER TABLE episodes ADD CONSTRAINT episodes_transcription_status_check
  CHECK (transcription_status IN ('pending', 'queued', 'processing', 'ready', 'failed'));

ALTER TABLE episodes
  ADD COLUMN IF NOT EXISTS image_url TEXT,
  ADD COLUMN IF NOT EXISTS transcription_attempts INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS transcription_error TEXT,
  ADD COLUMN IF NOT EXISTS language TEXT,
  ADD COLUMN IF NOT EXISTS summary TEXT,
  ADD COLUMN IF NOT EXISTS summary_attempts INTEGER NOT NULL DEFAULT 0;

-- Older workers appended failures to the user-visible description.
UPDATE episodes
SET description = regexp_replace(description, E'\\n\\n\\[Transcription failed: .*$', '')
WHERE description LIKE '%[Transcription failed: %';

CREATE INDEX IF NOT EXISTS idx_episodes_status ON episodes(transcription_status);

CREATE TABLE IF NOT EXISTS episode_chapters (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  episode_id UUID NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  start_sec DOUBLE PRECISION NOT NULL,
  end_sec DOUBLE PRECISION NOT NULL,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  embedding VECTOR(1536),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (episode_id, position)
);

-- context_text includes the neighbouring passages and is what gets embedded;
-- text stays the passage itself for display and citation.
ALTER TABLE transcript_segments
  ADD COLUMN IF NOT EXISTS context_text TEXT,
  ADD COLUMN IF NOT EXISTS search_tsv TSVECTOR
    GENERATED ALWAYS AS (to_tsvector('simple', text)) STORED;

CREATE INDEX IF NOT EXISTS idx_transcript_segments_search
  ON transcript_segments USING gin (search_tsv);
CREATE INDEX IF NOT EXISTS idx_transcript_segments_episode_start
  ON transcript_segments(episode_id, start_sec);

-- ivfflat built on an empty table has poor recall. HNSW needs no training data.
DROP INDEX IF EXISTS idx_transcript_segments_embedding;
CREATE INDEX IF NOT EXISTS idx_transcript_segments_embedding_hnsw
  ON transcript_segments USING hnsw (embedding vector_cosine_ops);

-- Jobs can target a single episode; heartbeat_at lets a crashed worker's job
-- be picked up again.
ALTER TABLE ingest_jobs
  ADD COLUMN IF NOT EXISTS episode_id UUID REFERENCES episodes(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS heartbeat_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_ingest_jobs_status_created ON ingest_jobs(status, created_at);
CREATE INDEX IF NOT EXISTS idx_ingest_jobs_source_created ON ingest_jobs(source_id, created_at DESC);
