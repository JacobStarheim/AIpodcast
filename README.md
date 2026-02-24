# AI Podcast Voice Q&A Prototype

This repository implements a local prototype for transcript-grounded podcast Q&A with voice input/output.

## Implemented Scope

- Flutter mobile app at `apps/mobile_flutter` with:
  - Episode list + pagination
  - Episode detail/transcription status
  - Push-to-talk voice question flow
  - Text answer + spoken answer playback
  - Citation list with tap-to-seek into episode audio
- Node/TypeScript API at `apps/api` with `/v1` routes:
  - `POST /v1/admin/sources`
  - `POST /v1/admin/ingest/run`
  - `GET /v1/episodes`
  - `GET /v1/episodes/:episodeId`
  - `POST /v1/voice/transcribe`
  - `POST /v1/qa/answer`
  - `POST /v1/voice/synthesize`
- Worker at `apps/worker` for RSS ingest, transcription, chunking, embeddings, and transcript storage
- Shared API types at `packages/shared-types`
- Postgres + pgvector via Docker in `infrastructure/docker-compose.yml`
- SQL schema/init in `infrastructure/init.sql`
- Seed helper script: `scripts/seed.sh`

## Architecture

1. RSS source added via admin route.
2. Ingest job queued via admin route.
3. Worker fetches RSS episodes and upserts metadata.
4. Worker downloads pending episode audio, transcribes, chunks, embeds, stores transcript segments.
5. Mobile app records voice question and sends to `/v1/voice/transcribe`.
6. App sends transcription text to `/v1/qa/answer`.
7. API retrieves top transcript chunks and only answers when retrieval confidence is sufficient.
8. App sends answer text to `/v1/voice/synthesize`, plays returned MP3.
9. Citation tap seeks episode audio player to citation timestamp.

## Guardrails

- Strict grounding: answers are based only on retrieved transcript chunks.
- Retrieval threshold gate (`MIN_GROUNDING_SCORE`) enforces refusal behavior.
- Non-refusal responses must include citations.

## Local Setup

### Prerequisites

- Node.js 20+
- npm 10+
- Docker
- Flutter SDK 3.3+
- OpenAI API key

### 1) Start Postgres + pgvector

```bash
cd infrastructure
docker compose up -d
```

### 2) Install Node dependencies

```bash
cd ..
npm install
```

### 3) Configure env files

```bash
cp apps/api/.env.example apps/api/.env
cp apps/worker/.env.example apps/worker/.env
```

Set `OPENAI_API_KEY` in both files.

### 4) Start API and worker

```bash
npm run dev:api
# in another shell
npm run dev:worker
```

### 5) Seed a source and ingest job

```bash
API_BASE_URL=http://localhost:4000 ADMIN_KEY=dev-admin ./scripts/seed.sh
```

### 6) Run Flutter app

```bash
cd apps/mobile_flutter
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000
```

For iOS simulator on macOS, `http://localhost:4000` is typically correct.

## Tests

### API tests

```bash
npm --workspace apps/api test
```

Coverage includes:
- Route contract checks across all `/v1` endpoints
- Retrieval ranking/grounding guardrail behavior
- Mocked latency budget check

### Worker tests

```bash
npm --workspace apps/worker test
```

Coverage includes:
- RSS parse + dedupe by GUID
- Transcript chunk continuity

### Flutter tests

```bash
cd apps/mobile_flutter
flutter test
```

Coverage includes:
- Episode pagination behavior via controller
- Voice state machine transitions
- Citation seek behavior
- Pending/network/refusal failure paths

## Operations Runbook

See `RUNBOOK.md` for startup, validation, and troubleshooting steps.
