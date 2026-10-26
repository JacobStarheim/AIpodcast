-- Accounts. Users are created by an administrator; there is no sign-up.
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL,
  name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  disabled BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users (lower(email));

-- Only a hash of each session token is stored.
CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  last_used_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

-- Fixed-window request counters shared by every API process.
CREATE TABLE IF NOT EXISTS rate_limits (
  key TEXT NOT NULL,
  window_start TIMESTAMPTZ NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (key, window_start)
);

-- Audio minutes sent for transcription per UTC day, for the daily limit.
CREATE TABLE IF NOT EXISTS transcription_usage (
  day DATE PRIMARY KEY,
  seconds DOUBLE PRECISION NOT NULL DEFAULT 0
);

-- Periodic feed refresh and automatic transcription of new episodes.
ALTER TABLE rss_sources
  ADD COLUMN IF NOT EXISTS auto_transcribe BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS auto_transcribe_since TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_refreshed_at TIMESTAMPTZ;

-- The exact file that was transcribed. Podcasts with dynamically inserted ads
-- serve different audio on each download, so playback must use this copy for
-- transcript times to match. first_seen_at tells new episodes from old ones.
ALTER TABLE episodes
  ADD COLUMN IF NOT EXISTS audio_file TEXT,
  ADD COLUMN IF NOT EXISTS audio_mime TEXT,
  ADD COLUMN IF NOT EXISTS audio_bytes BIGINT,
  ADD COLUMN IF NOT EXISTS first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
