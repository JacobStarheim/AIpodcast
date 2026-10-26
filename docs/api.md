# HTTP API

JSON shapes are defined in [`packages/shared-types/src/index.ts`](../packages/shared-types/src/index.ts).
All paths are relative to the API origin (default `http://localhost:4000`).

## Authentication

Users sign in with email and password and send the returned session token on
every request except `GET /health`, `POST /v1/auth/login` and the signed media
URLs:

```
Authorization: Bearer <token>
```

Accounts are created by an administrator (`npm run user:create` or
`POST /v1/admin/users`); there is no public sign-up. Sessions last 30 days.
A request with a missing, expired or revoked token gets `401`.

`APP_API_KEY` is optional. When it is set, it is also accepted as a bearer
token, for scripts such as the smoke test and the eval runner; keep it secret
or leave it unset. Admin routes (`/v1/admin/*`) use `x-admin-key: <ADMIN_KEY>`.

### `POST /v1/auth/login`

Body `LoginRequest`. Returns `LoginResponse`, or `401` with
`invalid email or password`. Limited to 10 attempts per 15 minutes per client.

### `POST /v1/auth/logout`

Revokes the current session token. Returns `204`.

### `GET /v1/me`

Returns the signed-in `User`.

## Errors and limits

Errors use `{ "error": string, "requestId"?: string }`.

| Status | Meaning |
| --- | --- |
| 400 | Invalid input; `error` describes it. |
| 401 | Missing or wrong key. |
| 404 | Unknown episode or source. |
| 409 | Episode is not ready for questions. |
| 413 | Uploaded audio is too large (25 MB). |
| 429 | Rate limit reached; `Retry-After` gives seconds to wait. With `code: "transcription_budget_exceeded"` the daily transcription limit is used up. |
| 500 | Internal failure. Details are logged by the API under `requestId`, never returned. |

Rate limits are fixed windows per signed-in user (per IP for login), stored
in PostgreSQL so several API processes share them:

| Routes | Limit |
| --- | --- |
| `POST /v1/qa/answer` | 30 per minute |
| `POST /v1/voice/transcribe`, `POST /v1/voice/synthesize` | 20 per minute each |
| `GET /v1/podcasts/search` | 30 per minute |
| `POST /v1/sources` | 10 per hour |
| `POST /v1/episodes/:id/transcribe` | 10 per hour |
| Other `GET` routes | 300 per minute |

## Library

### `GET /v1/podcasts/search?q=<text>`

Searches the public Apple Podcasts directory. Returns `PodcastSearchResponse`
with up to 15 results that have an RSS feed.

### `GET /v1/sources`

Returns `SourceListResponse`: the podcasts in the library, episode counts and
the latest import job. `lastJob.status = "failed"` with `lastJob.error`
explains a feed that could not be imported.

### `PATCH /v1/sources/:id`

Body `UpdateSourceRequest`. With `autoTranscribe: true`, episodes that the
periodic feed refresh finds from now on are transcribed automatically, within
the daily limit. Returns the updated `SourceSummary`.

### `POST /v1/sources`

Body `AddSourceRequest`. Adds a podcast feed and queues a metadata import: the
worker lists its episodes as `pending` without transcribing any of them.
Returns `201` with `SourceSummary`, or `200` with the existing source when the
feed is already in the library. Only `http` and `https` URLs are accepted; the
worker also refuses private network addresses unless explicitly allowed.

### `GET /v1/episodes`

Query: `sourceId`, `q` (title/description search), `status`
(`ready`, `pending`, `queued`, `processing`, `failed`; repeatable or comma
separated), `cursor`, `limit` (1–50, default 20). Returns
`EpisodeListResponse`, newest first.

### `GET /v1/episodes/:id`

Returns `EpisodeDetailResponse`. Ready episodes include `summary`, `language`
and `chapters` when the summary step succeeded.

### `POST /v1/episodes/:id/transcribe`

Requests transcription of one episode. Returns `202` with
`TranscribeEpisodeResponse` and status `queued`. Requesting an episode that is
already `ready`, `queued` or `processing` returns `200` with `jobId: null` and
does nothing. A `failed` episode can be requested again.

Poll `GET /v1/episodes/:id` until `transcriptionStatus` is `ready` or `failed`.
A one-hour episode usually takes about two minutes.

Transcription has a daily limit in audio minutes (`DAILY_TRANSCRIPTION_MINUTES`,
default 180, shared by all users). A request that would exceed it gets `429`
with `code: "transcription_budget_exceeded"`.

### `GET /v1/usage`

Returns `UsageResponse`: transcription minutes used today (UTC) and the limit.

### Playback and `playbackUrl`

Every episode has `playbackUrl`. For transcribed episodes it points to the
exact audio file that was transcribed, served by
`GET /v1/media/episodes/:id?exp=<unix>&sig=<hmac>` with HTTP Range support and
no `Authorization` header (the signature authorizes it; links expire after 12
hours, so refresh the episode before then). Otherwise it equals `audioUrl`. A
relative `playbackUrl` is relative to the API origin.

Play `playbackUrl`, not `audioUrl`: many podcasts insert ads dynamically, so
two downloads of `audioUrl` can differ by many seconds and transcript times
would not match.

## Questions

### `POST /v1/qa/answer`

Body `QARequest`:

- `questionText` (required, at most 1000 characters).
- `episodeId`: limit the search to one episode. The episode must be `ready`
  (otherwise `409`). Omit it to search every ready episode.
- `positionSec`: current playback position in `episodeId`. The transcript
  heard during the last 90 seconds is added as evidence, so questions such as
  "what did they mean just now?" work.
- `history`: earlier turns, oldest first. Used to understand follow-up
  questions; only the last 6 turns are used and each text is truncated to
  1000 characters.
- `topK`: 1–12, default 10. Each hit also brings the passages directly before
  and after it.

Returns `QAResponse`. Citations have `kind: "segment"` (a transcript passage)
or `kind: "chapter"` (a chapter from the episode summary). `playFromSec` is the
estimated start of the cited sentence (a second or two early); play from there.
Refusals are written in the language of the question. When the evidence is
insufficient, `grounded` is `false`, `citations` is empty and `refusalReason`
is `insufficient_retrieval_confidence` or `insufficient_grounded_citations`.

### `POST /v1/qa/answer/stream`

Same body as `/v1/qa/answer`. Responds with `text/event-stream`; every event is
one `data: <QAStreamEvent JSON>` line followed by a blank line:

1. `{"type":"status","stage":"searching"}`, then `{"type":"status","stage":"answering"}`.
2. Zero or more `{"type":"delta","text":"..."}` with the answer text as it is
   written.
3. Exactly one final `{"type":"done","response":QAResponse}` or
   `{"type":"error","error":"..."}`.

The `done` response is authoritative: it may be a refusal even after deltas were
sent (for example when the answer cited nothing valid), so replace the streamed
text with it. Validation errors before streaming starts use normal JSON errors.

### `POST /v1/voice/transcribe`

Multipart form with an `audio` file (max 25 MB) and an optional `episodeId`
field. With `episodeId`, names from that episode (description and chapters) are
passed to the transcription model as spelling hints. Returns
`{ "text": string, "durationMs": number }`.

### `POST /v1/voice/synthesize`

Body `{ "text": string }` (at most 6000 characters). Returns
`{ "audioBase64": string, "mimeType": "audio/wav" }`.

## Admin

These routes require `x-admin-key`.

- `POST /v1/admin/users` with `{ "email", "name", "password", "role"? }`
  creates an account (`role` defaults to `user`; passwords need 10+ characters).
- `POST /v1/admin/episodes/:id/retranscribe` transcribes an episode again, for
  example after improving name hints. The episode is unavailable for questions
  until it is ready again.

- `POST /v1/admin/sources` with `{ "name", "rssUrl" }` creates a source.
- `POST /v1/admin/ingest/run` with `{ "sourceId"?, "maxEpisodesPerSource"? }`
  (0–100; 0 imports the episode list only) queues an import that also
  transcribes the newest untranscribed episodes.

## Health

`GET /health` returns `{ "ok": true }` without authentication. It does not check
the database; `GET /v1/sources` does.
