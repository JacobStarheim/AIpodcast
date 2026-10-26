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
requires `ADMIN_KEY`. Secrets belong only in backend environment files, not the
mobile app. The default model names are `gpt-transcribe`, `gpt-6-luna`,
`gpt-5.4-mini` (question rewriting), `gpt-realtime-2.1-mini`, and
`text-embedding-3-small`.

People sign in with their own accounts. Create one with
`USER_PASSWORD=... npm run user:create -- --email <email> --name <name>`
(`--admin` for an administrator), or with `POST /v1/admin/users`. Sessions last
30 days. `APP_API_KEY` is an optional service token for the scripts; leave it
empty when others can reach the API.

API and worker must share `AUDIO_STORAGE_DIR`: the worker keeps each transcribed
file there and the API serves it to the app.

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
SELECT day, ROUND(seconds / 60) AS minutes FROM transcription_usage ORDER BY day DESC LIMIT 7;
SELECT name, auto_transcribe, last_refreshed_at FROM rss_sources;
SELECT email, role, created_at FROM users;
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
Sign in with an account created as above. The demo's audio URL is loopback, so
Android needs:

```bash
adb reverse tcp:4100 tcp:4100
```

To use `http://127.0.0.1:4000` as the Android API URL too, also run
`adb reverse tcp:4000 tcp:4000` and provide the corresponding `API_BASE_URL`
Flutter define.

Run `flutter devices`, then `flutter run -d <device-id>` from
`apps/mobile_flutter`. Verify on each target:

1. Sign in, open the account button and confirm the name; the library shows the
   transcription minutes left today.
2. Open the Aurora demo episode and confirm `Ready`.
3. Type “How many sensors does Aurora carry?” and check that the answer appears
   while it is written, says 24, and has a playable citation.
4. Tap the citation and confirm that the episode plays just before the quoted
   words.
5. Pause, seek with the progress bar, leave the episode and come back; playback
   resumes where it stopped.
6. Start playback, lock the phone (or go to the home screen) and check that it
   keeps playing and can be paused from the lock screen.
7. While the episode plays, ask “What did they just say?”; playback pauses, the
   answer uses the passage just heard, and playback resumes.
8. Ask a follow-up (“And where does it leave from?”) and confirm it is understood.
   Close and reopen the app; the conversation is still there.
9. Allow microphone access, record a question, and confirm transcription and an
   answer.
10. Enable spoken answers, verify playback, and use the stop control.
11. Ask for a fact absent from the episode, in Norwegian, and verify a Norwegian
    refusal.
12. Search for a podcast, add it, turn on automatic transcription in its
    settings, and transcribe one episode.

Passage times are the boundaries of one audio clip, 10–30 seconds. The answer
model quotes the words it relies on, and **Listen from** starts about 1.5 seconds
before where that quote falls in the clip, estimated from its position in the
text. Synthesis returns WAV audio from the Realtime model.

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

The API limits requests per signed-in user, and sign-in attempts per client
address (see [docs/api.md](docs/api.md)). The counters are in the `rate_limits`
table, so every API process shares them. Wait for the time in the message.
Behind a reverse proxy, set `TRUST_PROXY` so sign-in attempts from different
clients are told apart.

### Transcription is refused with "Today's transcription limit is used up"

`DAILY_TRANSCRIPTION_MINUTES` (default 180) caps the audio transcribed per UTC
day, for requests and automatic transcription together; see
`transcription_usage`. A requested episode that does not fit is refused right
away (or fails without using up an attempt if the limit runs out while it waits);
automatic ones wait for the next day. Raise the limit in both the API and
worker environment, or set it to 0 to turn it off, and restart them.

### Someone cannot sign in, or should no longer have access

Wrong passwords and unknown addresses get the same answer. There is no password
reset: delete the account (`DELETE FROM users WHERE lower(email) =
lower('<email>');`, which also ends its sessions) and create it again. To remove
access but keep the account, run
`UPDATE users SET disabled = TRUE WHERE lower(email) = lower('<email>');`; its
sessions stop working at once.

### An episode plays but **Listen from** lands at the wrong place

Check that the episode has `audio_file` set and that the file exists in
`AUDIO_STORAGE_DIR`. Episodes transcribed before the audio was kept fall back
to the publisher's file, whose ads may differ from the transcribed copy. Queue a
new transcription with `POST /v1/admin/episodes/<id>/retranscribe`.

### Text answers work but spoken answers fail

Read the API log (500 responses include a `requestId` that appears there) and
confirm access to `gpt-realtime-2.1-mini`. The API converts Realtime PCM output
to WAV; the mobile client must accept `audio/wav`. Check
`.local/demo/answer.wav` and `.local/demo/answer-norwegian.wav` after the live
test. Text answers remain available when speech generation or playback fails.

### The app cannot reach the API or play citations

- Use the correct emulator/simulator API address. A 401 means the session ended
  or the account was disabled; the app returns to the sign-in screen.
- Reapply Android port forwarding after reconnecting or restarting the emulator.
- Episodes transcribed before the audio was kept still play from the publisher
  (for the demo, the demo server on port 4100). Transcribed episodes play from
  the API through signed links that expire after 12 hours; the app fetches a new
  link when one fails.
- A physical device needs URLs reachable from that device. The bundled loopback
  demo needs different serving/network configuration for physical hardware.
- Android debug/profile builds permit local HTTP; a release setup needs HTTPS
  (see [docs/deploy.md](docs/deploy.md)).

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
