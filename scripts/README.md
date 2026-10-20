# Local demo and live smoke test

These scripts exercise the running API, worker, database, and configured OpenAI
models. The live test uses paid API calls. It never substitutes model responses,
inserts a transcript, or writes embeddings directly.

Prerequisites: Node dependencies installed, macOS `say`, `ffmpeg` and `ffprobe`,
running PostgreSQL/API/worker, and configured `apps/api/.env` and
`apps/worker/.env`. Run from the repository root:

```bash
# Terminal 1: generates local speech assets once and keeps serving them.
npm run demo:serve

# Terminal 2: imports one short episode and tests the real voice flow.
npm run test:live
```

The demo is a fictional research voyage lasting approximately one minute.
Its known facts include a ship called Aurora carrying 24 sensors. The test
transcribes a spoken sensor question, passes the recognized text to Q&A, checks
the answer and citation times, asks for an unsupported fact, and synthesizes the
answer. The synthesized WAV must have valid headers and a plausible decoded
duration. A second short synthesis checks Norwegian text containing the number 24.

The harness reuses the existing source for `http://127.0.0.1:4100/feed.xml`,
reuses queued/processing jobs, and skips ingestion if that episode is already
ready. Failed jobs can be retried by running it again. Read-only database queries
identify existing records and report worker errors; application writes use the
local admin API. A Postgres advisory lock prevents overlapping smoke runs.

Generated assets and the latest report stay in the ignored `.local/` directory:

- `.local/demo/aurora.mp3`: episode audio.
- `.local/demo/question.wav`: spoken test question.
- `.local/demo/answer.wav`: latest synthesized response.
- `.local/demo/answer-norwegian.wav`: Norwegian synthesis containing numeric text.
- `.local/smoke-report.json`: checks, answer, citations, and failure details.

Keep the demo server running to play the episode on a simulator. For Android:

```bash
adb reverse tcp:4000 tcp:4000
adb reverse tcp:4100 tcp:4100
# Start Flutter with --dart-define=API_BASE_URL=http://127.0.0.1:4000
```

The iOS simulator can use `http://127.0.0.1:4000` directly. A physical device needs
additional network configuration; these scripts intentionally serve loopback
only.

Optional variables: `API_BASE_URL`, `DEMO_PORT`, `DEMO_BASE_URL`, `DEMO_VOICE`
(defaults to Samantha), `FFMPEG_PATH`, and `FFPROBE_PATH`. The API base and demo
base must be plain loopback HTTP origins. `ADMIN_KEY` and `DATABASE_URL` are read
from the API environment file unless overridden in the shell; values are never
printed. Model configuration comes from the running services.
The demo server binds IPv4 loopback, so `DEMO_BASE_URL` must use `127.0.0.1` or
`localhost`. When `DEMO_PORT` is omitted, the server derives its port from
`DEMO_BASE_URL`; when both are specified, their ports must match.
