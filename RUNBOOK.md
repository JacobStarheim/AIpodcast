# Runbook

## Startup

1. Start database:
   - `cd infrastructure && docker compose up -d`
2. Install dependencies:
   - `cd .. && npm install`
3. Configure env files:
   - `cp apps/api/.env.example apps/api/.env`
   - `cp apps/worker/.env.example apps/worker/.env`
4. Start services:
   - `npm run dev:api`
   - `npm run dev:worker`
5. Seed source/job:
   - `API_BASE_URL=http://localhost:4000 ADMIN_KEY=dev-admin ./scripts/seed.sh`
6. Launch Flutter app:
   - `cd apps/mobile_flutter && flutter pub get`
   - `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000`

## Health Checks

- API health:
  - `curl -s http://localhost:4000/health`
- Sources created:
  - `SELECT COUNT(*) FROM rss_sources;`
- Episodes discovered:
  - `SELECT COUNT(*) FROM episodes;`
- Segments embedded:
  - `SELECT COUNT(*) FROM transcript_segments;`
- Ingest job status:
  - `SELECT id, status, error, updated_at FROM ingest_jobs ORDER BY created_at DESC LIMIT 5;`

## Functional Verification

1. Confirm episodes show in app and at least one has `Ready` status.
2. Ask a question by push-to-talk; verify answer + citations.
3. Tap citation and verify playback seeks to cited timestamp.
4. Ask unsupported question and confirm refusal response.

## Common Issues

### Worker jobs stay queued

- Check worker logs for OpenAI/API errors.
- Confirm `OPENAI_API_KEY` is set in `apps/worker/.env`.
- Confirm DB connection URL is reachable.

### Episode status remains pending

- Audio download may fail due inaccessible `audio_url`.
- File may exceed `MAX_EPISODE_AUDIO_MB`.
- Check `ingest_jobs.error` and worker logs.

### QA always refuses

- Retrieval score may be below threshold.
- Lower `MIN_GROUNDING_SCORE` in `apps/api/.env` for experimentation.
- Ensure transcript segments exist for that episode.

### Flutter cannot reach API

- Android emulator should use `http://10.0.2.2:4000`.
- iOS simulator usually uses `http://localhost:4000`.
- Ensure API is running and not blocked by firewall.

## Reset (Local)

To reset DB contents:

1. `cd infrastructure`
2. `docker compose down -v`
3. `docker compose up -d`

Then reseed with `scripts/seed.sh`.
