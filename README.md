# AI Podcast Voice Q&A

A Flutter app for listening to podcasts and asking questions about their
transcripts. Questions can be typed or recorded. Answers include playable
citations and optional spoken playback.

## Listening and questions

Sign in with an account an administrator created (there is no sign-up). Find a
podcast in the Apple Podcasts directory (or paste an RSS link) and add it to the
library. The episode list is imported right away; choose **Transcribe** on an
episode to have it transcribed and indexed, which takes one to two minutes for a
one-hour episode. With **Transcribe new episodes automatically** turned on for a
podcast, new episodes are transcribed as they appear. Every feed is read again
hourly, and a daily limit on transcribed minutes keeps the cost predictable.

The player has play/pause, a progress bar with seeking, and remembers where you
stopped in each episode. It keeps playing in the background and on the lock
screen, with controls there and on headsets. The app plays the exact audio file
that was transcribed, kept by the server, because many podcasts insert different
ads into each download and the publisher's file would not match the transcript
times.

Ask while you listen: the question is sent with the current position, playback
pauses, and the transcript you heard during the last 90 seconds is part of the
evidence, so "what did they mean just now?" works. Playback resumes after the
answer. The answer appears while it is being written.

Questions can cover one episode or the whole library. Follow-up questions keep
the conversation, so "and what did she say about that?" is understood, and
conversations are still there after the app restarts. Ready episodes also get a
summary and chapters, which answer overview questions such as "what is this
episode about?". Answers show source excerpts and chapters; choose **Listen
from** to hear the cited passage. For voice input, tap to record and tap again to
send, or hold while speaking; cancel is available during recording.

The backend imports RSS episodes, transcribes their audio, stores embeddings in
PostgreSQL with pgvector, and retrieves evidence for each question. Its current
model configuration is:

| Purpose | Model | Integration |
| --- | --- | --- |
| Episode and question transcription | `gpt-transcribe` | Audio Transcriptions API |
| Rewriting questions into search queries | `gpt-5.4-mini` | Responses API with a strict JSON schema |
| Answers, summaries | `gpt-6-luna` | Responses API with strict JSON schemas, answers streamed |
| Spoken answers | `gpt-realtime-2.1-mini` | Realtime audio, returned to the app as WAV |
| Search embeddings | `text-embedding-3-small` | 1536-dimensional vectors |

### How an episode is indexed

1. The worker streams the audio file to disk (up to 500 MB by default) and
   refuses private network addresses unless explicitly allowed.
2. FFmpeg finds pauses and cuts the audio into clips of about 20 seconds (10–30),
   ending in a pause where possible so words are not split between requests.
3. Clips are transcribed four at a time. The request includes the podcast and
   episode title and the names found in the episode description, which helps
   with the spelling of names. Passage times are the real clip boundaries.
4. Each passage is embedded together with the end of the previous and the start
   of the next passage, in batched requests, and stored with a full-text index.
5. The model writes a summary and chapters with start times.
6. The downloaded file is kept (`AUDIO_STORAGE_DIR`) and the app plays it
   through signed links that expire after 12 hours.

A failed episode is retried by later imports up to three times. Permanent
failures, such as a missing file or audio above the size limit, are not retried
automatically, so they do not block other episodes; requesting the episode in
the app tries again.

### How a question is answered

1. The question and earlier turns are rewritten into one to three search queries,
   including a translation into the transcript language (for example a Norwegian
   question about an English episode). This runs while the question as asked is
   searched; a first question that already matches a passage closely is answered
   without waiting for it.
2. Vector search (HNSW) and keyword search (on word stems, so "fjorden" also
   finds "fjordene") run for every query and are merged by reciprocal rank fusion.
3. The passages just heard, the retrieved passages with their neighbours, and
   the episode's chapters go to the answer model. It cites passages with a short
   quote, which places **Listen from** a few seconds before the quoted words
   instead of at the start of the passage.
4. If no passage is similar enough, nothing matches the keywords, nothing was
   just heard, and the question is not about the episode as a whole, the API
   refuses without calling the answer model. Answers without a valid citation
   are refused too. Answers and refusals are in the language of the question.
   These checks do not guarantee that every claim is correct.

## Local setup

Run the commands below from the repository root unless stated otherwise.

Prerequisites:

- Node.js 20+ and npm.
- Docker with Compose. The included `pgvector/pgvector:pg16` image provides
  pgvector 0.8 or newer, which the filtered vector search needs.
- `ffmpeg` and `ffprobe` on `PATH`.
- A current Flutter stable SDK; the development environment uses Flutter 3.47.7.
- Xcode and an iOS simulator for iOS, or Android SDK and an emulator for Android.
- An OpenAI API key with access to the configured models.
- macOS `say` for generating the included local demo audio.

### Install and configure

```bash
npm ci
npm run build
cp -n apps/api/.env.example apps/api/.env
cp -n apps/worker/.env.example apps/worker/.env
npm run db:up
```

`npm run db:up` starts PostgreSQL and applies the migrations in
`infrastructure/migrations`. After pulling new changes, run `npm run db:migrate`;
the API and worker refuse to start on an outdated schema.

Set `OPENAI_API_KEY` in both backend `.env` files and `ADMIN_KEY` in the API
environment. Keep OpenAI keys in the backend environment. If the media tools are
elsewhere, set `FFMPEG_PATH` and `FFPROBE_PATH` in the worker environment.

Create an account to sign in to the app with. The password is read from the
environment so it does not end up in the shell history:

```bash
read -rs USER_PASSWORD && export USER_PASSWORD
npm run user:create -- --email you@example.com --name "Your Name" --admin
```

`APP_API_KEY` is an optional service token for the scripts (live test, eval).
The example sets `dev-app-key`; leave it empty on a server that others can reach.

The example worker environment sets `ALLOW_PRIVATE_NETWORK_FEEDS=true` so the
local demo feed on `127.0.0.1` can be imported. Set it to `false` when other
people can add feeds.

### Start the services

Use separate terminals:

```bash
npm run dev:api
```

```bash
npm run dev:worker
```

The API listens on port 4000. Verify database access as well as HTTP startup:

```bash
curl --fail http://localhost:4000/health
curl --fail -H 'Authorization: Bearer dev-app-key' http://localhost:4000/v1/sources
```

The worker reads every feed again each hour (`FEED_REFRESH_MINUTES`) and
transcribes at most `DAILY_TRANSCRIPTION_MINUTES` (180 by default) of audio per
UTC day, counting both requested and automatic transcriptions.

The HTTP API is described in [docs/api.md](docs/api.md).

### Verify the included demo first

Start the demo server in another terminal and keep it running:

```bash
npm run demo:serve
```

Then run:

```bash
npm run test:live
```

The demo serves a short fictional episode about the research ship Aurora on port
4100. The live test imports one episode through the normal worker, transcribes a
spoken question, checks an answer and citation times, verifies refusal for an
unsupported question, and validates English and Norwegian speech output. It uses
real, paid OpenAI calls. Repeated runs reuse the demo source and ready episode.

The latest result is saved to `.local/smoke-report.json`, with generated audio in
`.local/demo/`. See [scripts/README.md](scripts/README.md) for options and the
individual checks.

### Run Android or iOS

For the Android emulator, forward the demo audio port before launch. The feed
contains `127.0.0.1:4100` audio URLs, so this forwarding is needed even though the
API uses the emulator's host address:

```bash
adb reverse tcp:4100 tcp:4100
cd apps/mobile_flutter
flutter pub get
flutter run -d <android-device-id>
```

The Android default API URL is `http://10.0.2.2:4000`. Alternatively, run
`adb reverse tcp:4000 tcp:4000` and pass
`--dart-define=API_BASE_URL=http://127.0.0.1:4000`.

For the iOS simulator:

```bash
cd apps/mobile_flutter
flutter pub get
flutter run -d <ios-simulator-id>
```

The iOS default API URL is `http://localhost:4000`. Use `flutter devices` to find
device IDs. Sign in with the account created above. Allow microphone access for
recorded questions; typed questions work without it.

Physical devices need an API they can reach. See the
[mobile README](apps/mobile_flutter/README.md).

### Run it on a server

[docs/deploy.md](docs/deploy.md) sets up the API, worker and database with
Docker Compose behind Caddy, which gets an HTTPS certificate automatically. The
app is then built with `--dart-define=API_BASE_URL=https://your-domain`.

### Import your own podcast

The app's **Add podcast** sheet is the normal way. From the command line, the
seed helper adds a feed and transcribes its newest episodes:

```bash
RSS_URL='https://example.com/podcast/feed.xml' SOURCE_NAME='My podcast' MAX_EPISODES=1 npm run seed
```

The helper reads the configured admin key from `apps/api/.env` and reuses an
existing active source with that RSS URL. `MAX_EPISODES=0` imports only the
episode list. Transcription is billed per audio minute, so start with one
episode.

An episode becomes `ready` only after nonempty, timed transcript chunks and valid
embeddings are stored. An episode failure marks its ingest job `failed` and is
shown in the app with its reason; a new ingest job retries failed episodes (up to
the attempt limit) and skips ready ones.

## Checks and verification

```bash
npm run build
npm test
npm run test:db
cd apps/mobile_flutter
flutter analyze
flutter test
```

`npm run test:db` creates a throwaway `podcast_ai_test` database on the
configured server, applies the migrations twice (the second run must change
nothing), and runs the database suites (`*.db.test.ts`) against real
PostgreSQL. `npm test` skips those suites. GitHub Actions runs all of the above
on every push and pull request ([.github/workflows/ci.yml](.github/workflows/ci.yml)),
and `main` only accepts changes whose checks passed.

To measure answer quality on a real episode, transcribe it and run a question
set with known answers (paid model calls). There is an English and a Norwegian
set:

```bash
npm run eval -- --dataset scripts/eval/datasets/hard-fork-holmes.json
npm run eval -- --dataset scripts/eval/datasets/forklart-fordefjorden.json
```

See [docs/verification.md](docs/verification.md) for what has been verified and
the limits of these checks.

## Repository layout

- `apps/mobile_flutter`: Flutter Android/iOS client.
- `apps/api`: HTTP API, podcast search, retrieval, answer generation, voice input and output.
- `apps/worker`: RSS ingestion, audio segmentation, transcription, embeddings and summaries.
- `packages/shared-types`: shared TypeScript API contracts and the schema version.
- `infrastructure`: PostgreSQL/pgvector Compose services (local and production), Caddy and migrations.
- `scripts`: migrations, database tests, accounts, deterministic demo, live smoke test, eval and RSS seed helper.

See [RUNBOOK.md](RUNBOOK.md) for operational checks and recovery.
