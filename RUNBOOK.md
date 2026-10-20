# Runbook

## Startup

From the repository root:

```bash
npm ci
npm run build
npm run db:up
```

Create missing environment files from `apps/api/.env.example` and
`apps/worker/.env.example`, then configure the API key in both. The API also
requires `ADMIN_KEY`. Secrets belong only in backend environment files, not the
mobile app. The default model names are `gpt-transcribe`, `gpt-6-luna`,
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

Inspect `.local/smoke-report.json` for checks, answers, citations, and any failure.
The most recent completed verification passed all eight checks. Generated media
is under `.local/demo/`. The local demo recording is a known fictional fixture
for checking the complete pipeline.

For a fresh ingestion check, add a distinct source or episode and import only one
episode. Details and override variables are in [scripts/README.md](scripts/README.md).

## Service and database checks

```bash
curl --fail http://localhost:4000/health
curl --fail http://localhost:4000/v1/episodes
docker compose -f infrastructure/docker-compose.yml ps
```

`/health` only checks that the HTTP service responds. `/v1/episodes` also exercises
the database. Open a database session:

```bash
docker compose -f infrastructure/docker-compose.yml exec postgres \
  psql -U podcast -d podcast_ai
```

Useful read-only queries:

```sql
SELECT COUNT(*) FROM rss_sources;
SELECT transcription_status, COUNT(*) FROM episodes GROUP BY transcription_status;
SELECT COUNT(*) FROM transcript_segments WHERE embedding IS NOT NULL;
SELECT id, source_id, status, error, updated_at
FROM ingest_jobs ORDER BY created_at DESC LIMIT 5;
SELECT e.id, e.title, e.transcription_status, COUNT(ts.id) AS segment_count
FROM episodes e
LEFT JOIN transcript_segments ts ON ts.episode_id = e.id
GROUP BY e.id
ORDER BY e.updated_at DESC LIMIT 10;
```

## Mobile verification

Keep the API, worker, and demo server running. Android defaults to
`http://10.0.2.2:4000`; the iOS simulator defaults to `http://localhost:4000`.
The demo's audio URL is loopback, so Android needs:

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
4. Allow microphone access, record a question, and confirm transcription and an
   answer.
5. Enable spoken answers, verify playback, and use the stop control.
6. Ask for a fact absent from the episode and verify refusal.

Citation precision is roughly one 30-second audio clip. The model does not return
word timestamps; the worker uses the real boundaries of the clips it transcribes.
Synthesis returns WAV audio from the Realtime model.

## Failure diagnosis and recovery

### Jobs stay queued

- Confirm the worker process is running and points to the same database as the API.
- Check worker startup errors, including missing API configuration.
- Check the database query above for the exact job state.

### An episode or job failed

Read `ingest_jobs.error` before retrying. The worker continues processing other
episodes in the job, but reports the job as failed if any episode failed.
Possible causes include an unreachable RSS/audio URL, missing FFmpeg tools, model
access or billing errors, empty transcription, or invalid embeddings.

After correcting the cause, enqueue a new ingest job for the existing source
through `POST /v1/admin/ingest/run`, with its `sourceId` and
`maxEpisodesPerSource: 1`. The new job retries failed episodes; already ready
episodes are skipped. The seed helper can also reuse the existing RSS URL and
reads the admin key from `apps/api/.env`:

```bash
RSS_URL='https://example.com/podcast/feed.xml' MAX_EPISODES=1 npm run seed
```

For the included demo, rerun `npm run test:live`.

A `pending` episode may simply be outside the current job's episode limit.
Increasing that limit or enqueueing another job permits more episodes to run.

### A job remains processing after an interrupted worker

The worker claims queued jobs; an interrupted process may leave a job marked
`processing`. Confirm that no worker is still handling that job before manually
marking that specific interrupted job failed in PostgreSQL and enqueueing a new
job. The live harness reuses processing jobs, so it will wait until their state
changes.

### Episode audio is too large

`MAX_EPISODE_AUDIO_MB` limits downloads to 80 MB by default. The worker decodes an
accepted file once into roughly 30-second mono WAV clips, each below 25 MB, and
transcribes them separately. Text chunking alone would not solve the upload limit.
Raise the download limit only when you intend to process the larger episode and
have enough local memory, disk space, and API budget.

### Q&A refuses every question

First confirm that the selected episode is ready and has stored embeddings.
Check the actual transcribed text and ask a question that it directly answers.
Use the included Aurora question to distinguish pipeline failure from missing
evidence. Avoid lowering `MIN_GROUNDING_SCORE` merely to hide a missing transcript
or retrieval problem.

API and worker must use the same embedding model and dimensions. The database
stores 1536-dimensional vectors. Changing the embedding model requires rebuilding
stored embeddings consistently.

### Text answers work but spoken answers fail

Read the API error and confirm access to `gpt-realtime-2.1-mini`. The API converts
Realtime PCM output to WAV; the mobile client must accept `audio/wav`.
Check `.local/demo/answer.wav` and `.local/demo/answer-norwegian.wav` after the
live test. Text answers remain available when speech generation or playback fails.

### The app cannot reach the API or play citations

- Use the correct emulator/simulator API address.
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
cd apps/mobile_flutter
flutter analyze
flutter test
```

Also run the live smoke test and the mobile verification above. Unit tests use
controlled model/network responses and cannot replace those checks.

## Stop or reset local services

Stop API, worker, and demo terminals with Ctrl-C. `npm run db:down` stops the
database while preserving its Docker volume.

To deliberately delete all local database contents and initialize a fresh schema:

```bash
docker compose -f infrastructure/docker-compose.yml down -v
npm run db:up
```

Then rerun the demo import. Schema initialization runs when the database volume is
first created; editing `infrastructure/init.sql` alone does not migrate an
existing volume.
