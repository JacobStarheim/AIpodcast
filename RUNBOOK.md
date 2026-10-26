# Runbook

## Startup

From the repository root:

```bash
npm ci
npm run build
npm run db:up
```

`npm run db:up` starts PostgreSQL and applies pending migrations. Run
`npm run db:migrate` after pulling changes; it is safe to repeat.

Create missing environment files from `apps/api/.env.example` and
`apps/worker/.env.example`, then configure the OpenAI key in both. The API also
requires `ADMIN_KEY` and `APP_API_KEY`. Secrets belong only in backend
environment files, not the mobile app; the app key is a shared prototype key,
not a user account. The default model names are `gpt-transcribe`, `gpt-6-luna`,
`gpt-realtime-2.1-mini`, and `text-embedding-3-small`.

Check the worker's audio tools:

```bash
ffmpeg -version
ffprobe -version
```

Set `FFMPEG_PATH` and `FFPROBE_PATH` in the worker environment if needed. Start
`npm run dev:api` and `npm run dev:worker` in separate terminals. Restart a service
after changing its environment file.

## First functional check

Use the included short fixture before an arbitrary podcast feed:

```bash
# Keep this terminal running.
npm run demo:serve
```

In another terminal:

```bash
npm run test:live
```

The test uses real OpenAI calls and imports one short episode through the worker.
It checks episode readiness, stored transcript evidence and timestamps, spoken
question transcription, the supported answer, refusal for an unsupported fact,
and valid spoken output, including Norwegian numeric text. It reuses an existing
ready demo episode, so a repeat run does not automatically retranscribe it.
The demo feed is on `127.0.0.1`, so the worker needs
`ALLOW_PRIVATE_NETWORK_FEEDS=true`.

Inspect `.local/smoke-report.json` for checks, answers, citations, and any failure.
Generated media is under `.local/demo/`. The local demo recording is a known
fictional fixture for checking the complete pipeline.

For a real podcast, add it in the app (or with `npm run seed`) and transcribe one
episode first. Details and override variables are in
[scripts/README.md](scripts/README.md).

## Service and database checks

```bash
curl --fail http://localhost:4000/health
curl --fail -H "Authorization: Bearer $APP_API_KEY" http://localhost:4000/v1/sources
docker compose -f infrastructure/docker-compose.yml ps
```

`/health` only checks that the HTTP service responds. `/v1/sources` also
exercises the database and shows each podcast's latest import. Open a database
session:

```bash
docker compose -f infrastructure/docker-compose.yml exec postgres \
  psql -U podcast -d podcast_ai
```

Useful read-only queries:

```sql
SELECT version, applied_at FROM schema_migrations ORDER BY version;
SELECT COUNT(*) FROM rss_sources;
SELECT transcription_status, COUNT(*) FROM episodes GROUP BY transcription_status;
SELECT COUNT(*) FROM transcript_segments WHERE embedding IS NOT NULL;
SELECT id, source_id, episode_id, status, error, heartbeat_at, updated_at
FROM ingest_jobs ORDER BY created_at DESC LIMIT 5;
SELECT e.id, e.title, e.transcription_status, e.transcription_attempts,
       e.transcription_error, e.summary IS NOT NULL AS summarized,
       COUNT(ts.id) AS segment_count
FROM episodes e
LEFT JOIN transcript_segments ts ON ts.episode_id = e.id
GROUP BY e.id
ORDER BY e.updated_at DESC LIMIT 10;
```

## Mobile verification

Keep the API, worker, and demo server running. Android defaults to
`http://10.0.2.2:4000`; the iOS simulator defaults to `http://localhost:4000`.
Debug builds send the app key `dev-app-key`; pass
`--dart-define=API_KEY=...` if the API uses another key. The demo's audio URL is
loopback, so Android needs:

```bash
adb reverse tcp:4100 tcp:4100
```

To use `http://127.0.0.1:4000` as the Android API URL too, also run
`adb reverse tcp:4000 tcp:4000` and provide the corresponding `API_BASE_URL`
Flutter define.

Run `flutter devices`, then `flutter run -d <device-id>` from
`apps/mobile_flutter`. Verify on each target:

1. Open the Aurora demo episode and confirm `Ready`.
2. Type “How many sensors does Aurora carry?” and check that the answer says 24
   with a playable citation.
3. Tap the citation and confirm that the original episode plays near the passage
   containing the answer.
4. Pause, seek with the progress bar, leave the episode and come back; playback
   resumes where it stopped.
5. While the episode plays, ask “What did they just say?”; playback pauses, the
   answer uses the passage just heard, and playback resumes.
6. Ask a follow-up (“And where does it leave from?”) and confirm it is understood.
7. Allow microphone access, record a question, and confirm transcription and an
   answer.
8. Enable spoken answers, verify playback, and use the stop control.
9. Ask for a fact absent from the episode and verify refusal.
10. Search for a podcast, add it, and transcribe one episode.

Citation precision is one audio clip, 10–30 seconds. The model does not return
word timestamps; the worker uses the real boundaries of the clips it transcribes.
Synthesis returns WAV audio from the Realtime model.

## Failure diagnosis and recovery

### The API or worker exits with "Database schema is …"

The database is older than the code. Run `npm run db:migrate` and start the
service again.

### Jobs stay queued

- Confirm the worker process is running and points to the same database as the API.
- Check worker startup errors, including missing API configuration.
- Check the database query above for the exact job state.

### An episode or job failed

Read `episodes.transcription_error` (shown in the app) or `ingest_jobs.error`
before retrying. The worker continues processing other episodes in the job, but
reports the job as failed if any episode failed. Possible causes include an
unreachable RSS/audio URL, a private network address, missing FFmpeg tools,
model access or billing errors, empty transcription, or invalid embeddings.

Imports retry a failed episode up to `MAX_TRANSCRIPTION_ATTEMPTS` (default 3)
times. Permanent failures (missing file, no audio stream, above the size limit,
refused address) count as all attempts at once, so they do not block newer
imports. After correcting the cause, choose **Transcribe** on the episode in the
app, which retries regardless of the attempt count, or call
`POST /v1/episodes/<id>/transcribe`. For whole feeds, enqueue a new ingest job
through `POST /v1/admin/ingest/run` with its `sourceId` and
`maxEpisodesPerSource`, or rerun the seed helper:

```bash
RSS_URL='https://example.com/podcast/feed.xml' MAX_EPISODES=1 npm run seed
```

For the included demo, rerun `npm run test:live`.

A `pending` episode has not been requested. Request it in the app, or increase
the job's episode limit.

### A job remains processing after an interrupted worker

The worker refreshes `heartbeat_at` every 30 seconds while it works. A job
without a heartbeat for `STALE_JOB_MINUTES` (default 10) is queued again on the
next poll, and its episode returns to `queued`. Nothing needs to be done by hand;
wait for that interval or restart the worker.

### Summary or chapters are missing

Summaries are written after transcription; a failure there does not fail the
episode. The next import of that podcast tries again (two attempts in total).
Questions still work without a summary, but overview questions may be refused.

### Episode audio is too large

`MAX_EPISODE_AUDIO_MB` limits downloads to 500 MB by default. Downloads stream to
a temporary directory and are decoded into clips of 10–30 seconds, each well
below the 25 MB upload limit. Raise the limit only when you have the disk space
and API budget for the episode.

### A feed is refused as a private network address

The worker refuses feed and audio URLs that resolve to loopback, private or
link-local addresses, including after redirects. For the local demo, set
`ALLOW_PRIVATE_NETWORK_FEEDS=true` in the worker environment.

### Q&A refuses every question

First confirm that the selected episode is ready and has stored embeddings.
Check the actual transcribed text and ask a question that it directly answers.
Use the included Aurora question to distinguish pipeline failure from missing
evidence. Avoid lowering `MIN_GROUNDING_SCORE` merely to hide a missing transcript
or retrieval problem. If the search planning call fails, the API logs it and
searches with the question as asked.

API and worker must use the same embedding model and dimensions. The database
stores 1536-dimensional vectors. Changing the embedding model requires rebuilding
stored embeddings consistently.

### The app shows "Too many requests"

The API limits requests per client address (see [docs/api.md](docs/api.md)).
Wait for the time in the message. Behind a reverse proxy, set `TRUST_PROXY` so
clients are told apart.

### Text answers work but spoken answers fail

Read the API log (500 responses include a `requestId` that appears there) and
confirm access to `gpt-realtime-2.1-mini`. The API converts Realtime PCM output
to WAV; the mobile client must accept `audio/wav`. Check
`.local/demo/answer.wav` and `.local/demo/answer-norwegian.wav` after the live
test. Text answers remain available when speech generation or playback fails.

### The app cannot reach the API or play citations

- Use the correct emulator/simulator API address and app key (401 means a wrong key).
- Reapply Android port forwarding after reconnecting or restarting the emulator.
- Keep the demo server on port 4100 running; API availability alone does not make
  episode audio available.
- A physical device needs URLs reachable from that device. The bundled loopback
  demo needs different serving/network configuration for physical hardware.
- Android debug/profile builds permit local HTTP; a release setup needs HTTPS.

## Checks before handing off a build

```bash
npm run build
npm test
npm run test:db
cd apps/mobile_flutter
flutter analyze
flutter test
```

Also run the live smoke test and the mobile verification above. Unit tests use
controlled model/network responses and cannot replace those checks.

## Schema changes

Add a new file `infrastructure/migrations/NNN_description.sql` and set
`SCHEMA_VERSION` in `packages/shared-types/src/index.ts` to `NNN`. Never edit a
migration that has been applied somewhere. CI checks that the two match and that
the migrations apply cleanly twice.

## Stop or reset local services

Stop API, worker, and demo terminals with Ctrl-C. `npm run db:down` stops the
database while preserving its Docker volume.

To deliberately delete all local database contents and start with a fresh schema:

```bash
docker compose -f infrastructure/docker-compose.yml down -v
npm run db:up
```

Then rerun the demo import.
