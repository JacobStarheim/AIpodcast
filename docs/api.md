# HTTP API

JSON shapes are defined in [`packages/shared-types/src/index.ts`](../packages/shared-types/src/index.ts).
All paths are relative to the API origin (default `http://localhost:4000`).

## Authentication

Every route except `GET /health` requires the app key:

```
Authorization: Bearer <APP_API_KEY>
```

`APP_API_KEY` is set in `apps/api/.env`. The Flutter app receives it with
`--dart-define=API_KEY=...`; debug builds default to `dev-app-key`, which matches
the example environment. This is a shared app key for a prototype, not per-user
accounts. Admin routes (`/v1/admin/*`) use `x-admin-key: <ADMIN_KEY>` instead.

## Errors and limits

Errors use `{ "error": string, "requestId"?: string }`.

| Status | Meaning |
| --- | --- |
| 400 | Invalid input; `error` describes it. |
| 401 | Missing or wrong key. |
| 404 | Unknown episode or source. |
| 409 | Episode is not ready for questions. |
| 413 | Uploaded audio is too large (25 MB). |
| 429 | Rate limit reached; `Retry-After` gives seconds to wait. |
| 500 | Internal failure. Details are logged by the API under `requestId`, never returned. |

Rate limits per client (key and IP) are fixed windows:

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
A one-hour episode usually takes a few minutes.

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
- `topK`: 1–12, default 6.

Returns `QAResponse`. Citations have `kind: "segment"` (a transcript passage)
or `kind: "chapter"` (a chapter from the episode summary). Both carry
`startSec`, so the client can play from there. When the evidence is
insufficient, `grounded` is `false`, `citations` is empty and `refusalReason`
is `insufficient_retrieval_confidence` or `insufficient_grounded_citations`.

### `POST /v1/voice/transcribe`

Multipart form with an `audio` file (max 25 MB). Returns
`{ "text": string, "durationMs": number }`.

### `POST /v1/voice/synthesize`

Body `{ "text": string }` (at most 6000 characters). Returns
`{ "audioBase64": string, "mimeType": "audio/wav" }`.

## Admin

Both routes require `x-admin-key`.

- `POST /v1/admin/sources` with `{ "name", "rssUrl" }` creates a source.
- `POST /v1/admin/ingest/run` with `{ "sourceId"?, "maxEpisodesPerSource"? }`
  (0–100; 0 imports the episode list only) queues an import that also
  transcribes the newest untranscribed episodes.

## Health

`GET /health` returns `{ "ok": true }` without authentication. It does not check
the database; `GET /v1/sources` does.
