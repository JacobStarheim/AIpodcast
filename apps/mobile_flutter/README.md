# Mobile App (`apps/mobile_flutter`)

Flutter iOS/Android client for listening to podcasts and asking questions about
their transcripts. The HTTP contract is described in [`docs/api.md`](../../docs/api.md).

## Features

- **Player**: play, pause and resume the selected episode, with a progress bar
  showing elapsed and total time. Drag or tap the bar to seek (before playback
  starts, this sets where it will start). The position is remembered per episode
  across app restarts; an episode that was finished starts over.
- **Ask about what you just heard**: while an episode is playing or paused, the
  composer shows a chip such as **About 12:34**. Asking a question (typed or by
  voice) sends that position with the question, pauses the episode, and resumes it
  after the answer (and the spoken answer) if it was playing. Dismiss the chip to
  ask without the position. If answering fails, playback stays paused.
- **Scope**: ask about **This episode** or the **Whole library**. Library questions
  search every transcribed episode and need at least one ready episode; the
  selected episode does not have to be ready. Citations from other episodes play
  that episode from the cited moment.
- **Follow-up questions**: each scope keeps its own conversation, newest answer
  at the bottom, and sends the last six grounded turns as context. **New
  conversation** clears it. Choosing another episode clears the episode
  conversation.
- **Library**: artwork, duration and transcript status (not transcribed, queued,
  transcribing, ready, failed with the reason). Filter by podcast or **Only
  ready**, and search titles and descriptions on the server. **Transcribe**
  requests a transcript for an episode (also from the episode card) and the app
  checks every 5 seconds until it is ready or failed.
- **Add podcast**: search the podcast directory or paste an RSS link. After
  adding, the sheet shows the import progress (checked every 5 seconds) or why it
  failed, and the episode list refreshes when the import completes. New podcasts
  arrive with their episode list only; transcribe the episodes you want to ask
  about.
- **Episode details**: summary, chapters and episode notes. Tap a chapter to play
  from its start.
- Voice questions: tap to record and tap again to send, or hold while speaking and
  release to send. **Cancel recording** discards it. Optional spoken answers;
  **Stop spoken answer** skips the rest.
- Transcript-grounded answers with full source excerpts and **Listen from**
  controls. Errors are short messages, for example
  "Too many requests, try again in 12 s." for a rate limit.

## Run

Start the API and worker from the repository root first; see the root README.
Then, from this directory:

```bash
flutter pub get
flutter run
```

### API key

Every request except `/health` sends `Authorization: Bearer <key>`. Pass the key
that matches `APP_API_KEY` in `apps/api/.env`:

```bash
flutter run --dart-define=API_KEY=your-app-key
```

Without `API_KEY`, debug builds use `dev-app-key` (the example environment's key)
and release or profile builds send no key, so always pass it for those builds.
This is a shared prototype key, not a per-user secret: anything compiled into an
app can be extracted from it.

### API address

The default API address is `http://10.0.2.2:4000` on an Android emulator and
`http://localhost:4000` on an iOS simulator. To use a physical device, supply the
server's reachable address instead:

```bash
flutter run --dart-define=API_BASE_URL=http://YOUR_COMPUTER_LAN_IP:4000 \
  --dart-define=API_KEY=your-app-key
```

Allow microphone access when prompted to record a voice question. Typed questions
work without microphone permission. Use the speaker icon beside the voice control
to turn spoken answers on or off.

Android debug/profile builds allow HTTP for local development. Use an HTTPS API
endpoint in an Android release build. iOS allows local networking and includes the
microphone and local-network permission descriptions.

The app identifier is `io.github.jacobstarheim.aipodcast` on both platforms.

## Checks

```bash
flutter analyze
flutter test
```

Tests use fakes for the API, recorder and audio player. They cover the HTTP
contract (auth header, query parameters, request bodies, error parsing including
`Retry-After`), defensive model parsing, play/pause/seek and remembered positions,
position-aware questions and resuming playback, conversation history and scopes,
transcription and import polling, the add-podcast flow, chapter playback, and
layouts on a 320×568 screen with large text and an open keyboard. Native device
recording and playback still require a simulator or device test.
