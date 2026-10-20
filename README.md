# AI Podcast Voice Q&A

A local Flutter app for listening to podcasts and asking questions about their
transcripts. Questions can be typed or recorded. Answers include playable
citations and optional spoken playback.

## Listening and questions

The refreshed interface uses a warm theme and custom local artwork. Search the
episodes already loaded in the library, open their details, or play and stop the
original audio. A pinned question composer keeps typed questions and suggestions
within reach. For voice input, tap to record and tap again to send, or hold while
speaking; cancel is available during recording.

Answers show the latest question, clear progress and error messages, and source
excerpts. Open an excerpt and choose **Listen from** to hear the cited passage.

The backend imports RSS episodes, transcribes their audio, stores embeddings in
PostgreSQL with pgvector, and retrieves evidence for each question. Its current
model configuration is:

| Purpose | Model | Integration |
| --- | --- | --- |
| Episode and question transcription | `gpt-transcribe` | Audio Transcriptions API |
| Answers | `gpt-6-luna` | Responses API with a strict JSON schema |
| Spoken answers | `gpt-realtime-2.1-mini` | Realtime audio, returned to the app as WAV |
| Search embeddings | `text-embedding-3-small` | 1536-dimensional vectors |

Episode audio is decoded into roughly 30-second WAV clips before transcription.
Citation times come from the actual clip boundaries; they identify a short audio
passage, not the exact word where a claim starts. A retrieval threshold, validated
citations, and model instructions support refusal when the evidence is
insufficient. These checks do not guarantee that every generated claim is correct.

## Local setup

Run the commands below from the repository root unless stated otherwise.

Prerequisites:

- Node.js 20+ and npm.
- Docker with Compose.
- `ffmpeg` and `ffprobe` on `PATH`.
- A current Flutter stable SDK; the development environment uses Flutter 3.47.7.
- Xcode and an iOS simulator for iOS, or Android SDK and an emulator for Android.
- An OpenAI API key with access to the configured models.
- macOS `say` for generating the included local demo audio.

### Install and configure

```bash
npm ci
npm run build
npm run db:up
cp -n apps/api/.env.example apps/api/.env
cp -n apps/worker/.env.example apps/worker/.env
```

Set `OPENAI_API_KEY` in both backend `.env` files. Set `ADMIN_KEY` in the API
environment. The example database URL matches the included Docker service.
Keep API keys in the backend environment; the Flutter app only needs the API URL.
If the media tools are elsewhere, set `FFMPEG_PATH` and `FFPROBE_PATH` in the
worker environment.

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
curl --fail http://localhost:4000/v1/episodes
```

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
device IDs. Allow microphone access for recorded questions; typed questions work
without it. Keep the demo server running for citation playback.

Physical devices need reachable API and audio URLs; the included demo server
serves loopback only. See the [mobile README](apps/mobile_flutter/README.md).

### Import your own podcast

After the included demo passes, add one episode from an RSS feed:

```bash
RSS_URL='https://example.com/podcast/feed.xml' SOURCE_NAME='My podcast' MAX_EPISODES=1 npm run seed
```

The helper reads the configured admin key from `apps/api/.env` and reuses an
existing active source with that RSS URL. Start with one episode to check audio
availability and transcription before importing more. The worker's default
download limit is 80 MB per source episode. It splits accepted files into small
WAV uploads below the transcription API's 25 MB file limit.

An episode becomes `ready` only after nonempty, timed transcript chunks and valid
embeddings are stored. An episode failure marks its ingest job `failed`; a new
ingest job retries failed episodes and skips already ready ones.

## Checks and verification

```bash
npm run build
npm test
cd apps/mobile_flutter
flutter analyze
flutter test
```

Backend verification for this revision passed the TypeScript build, 40 API tests,
17 worker tests, and all eight checks in the real live smoke test. Worker tests
include actual FFmpeg segmentation; API unit tests use simulated model responses.
The live smoke report provides separate evidence for the real services.

Flutter analysis is clean and 63 automated tests passed. Coverage includes
320×568 layouts at 1.8× text scale with a 260-pixel keyboard, library retry,
microphone accessibility actions, questions, and playback.

The refreshed app built and ran on Android and an iPhone 17 simulator running
iOS 26.5. Native checks passed for the library, episode playback, typed Q&A, and
voice questions against the real backend. Android's tap and hold recording flows
passed, as did both recording flows on iOS. Episode rows and source playback expose
button actions to accessibility services; selecting an episode closes the library,
and source excerpts support playback and stopping. Physical devices remain
untested; the live fixture is short and citation precision is about 30 seconds.

See [docs/verification.md](docs/verification.md) for the observations and limits of
these checks.

## Repository layout

- `apps/mobile_flutter`: Flutter Android/iOS client.
- `apps/api`: HTTP API, retrieval, answer generation, voice input and output.
- `apps/worker`: RSS ingestion, audio segmentation, transcription and embeddings.
- `packages/shared-types`: shared TypeScript API contracts.
- `infrastructure`: PostgreSQL/pgvector Compose service and schema.
- `scripts`: deterministic demo, live smoke test and RSS seed helper.

See [RUNBOOK.md](RUNBOOK.md) for operational checks and recovery.
