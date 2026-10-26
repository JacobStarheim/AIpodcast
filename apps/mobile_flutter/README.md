# Mobile App (`apps/mobile_flutter`)

Flutter iOS/Android client for listening to podcasts and asking questions about
their transcripts. The HTTP contract is described in [`docs/api.md`](../../docs/api.md)
and the JSON shapes in [`packages/shared-types`](../../packages/shared-types/src/index.ts).

## Features

- **Accounts**: sign in with the email and password an administrator created
  (there is no sign-up in the app). The session token is kept in the iOS
  Keychain / Android Keystore-backed storage (`flutter_secure_storage`), never in
  shared preferences, and is restored on the next start. The account button in
  the header shows who is signed in and has **Sign out**, which stops playback,
  revokes the token on the server and returns to the sign-in screen. Any `401`
  (expired or revoked session) clears the token and shows the sign-in screen
  with "Your session has ended. Please sign in again."
- **Player**: play, pause and resume the selected episode, with a progress bar
  showing elapsed and total time. Drag or tap the bar to seek (before playback
  starts, this sets where it will start). The position is remembered per episode
  across app restarts; an episode that was finished starts over.
- **Plays the transcribed audio**: the app always plays the episode's
  `playbackUrl` (resolved against the API base URL when it is relative), never
  the publisher's `audioUrl`, because podcasts insert ads dynamically and
  transcript times only match the file that was transcribed. Signed links expire
  after 12 hours: when a link fails to load, or the stream breaks while playing,
  the app fetches the episode again once and continues with the fresh link from
  the same position.
- **Background playback and lock screen controls**: episodes keep playing when
  the app is in the background or the phone is locked. The lock screen,
  notification, headset buttons and car show the title, podcast and artwork with
  play/pause, back 15 s, forward 30 s and a scrubber. These commands go through
  the app, so they follow the same rules as the on-screen buttons (for example
  they wait while a question is being recorded or answered).
- **Ask about what you just heard**: while an episode is playing or paused, the
  composer shows a chip such as **About 12:34**. Asking a question (typed or by
  voice) sends that position with the question, pauses the episode, and resumes it
  after the answer (and the spoken answer) if it was playing. Dismiss the chip to
  ask without the position. If answering fails, playback stays paused.
- **Streaming answers**: the answer shows what the server is doing ("Searching
  the episode…", "Answering…") and its text as it is written. The final answer
  then replaces the streamed text; it can still be a refusal, which is shown in
  the language of the question.
- **Scope**: ask about **This episode** or the **Whole library**. Library questions
  search every transcribed episode and need at least one ready episode; the
  selected episode does not have to be ready. Citations from other episodes play
  that episode from the cited moment.
- **Conversations survive restarts**: each episode and the library keep their
  own conversation, newest answer at the bottom, and send the last six grounded
  turns as context. Conversations are stored on the device per account (the
  newest 30 turns of the 20 most recently used conversations) and come back when
  you open that episode again. **New conversation** clears it, also on the
  device.
- **Library**: artwork, duration and transcript status (not transcribed, queued,
  transcribing, ready, failed with the reason). Filter by podcast or **Only
  ready**, and search titles and descriptions on the server. **Transcribe**
  requests a transcript for an episode (also from the episode card) and the app
  checks every 5 seconds until it is ready or failed.
- **Daily transcription limit**: the server transcribes a limited number of audio
  minutes per day (shared by everyone). The minutes left today are shown next to
  **Transcribe** on the episode card (with a note when the episode is longer) and
  in the library. When the limit is used up, a request says "Today’s
  transcription limit is used up." instead of the generic rate-limit message.
- **Automatic transcription per podcast**: filter the library by a podcast to see
  its settings: **Transcribe new episodes automatically** ("New episodes are
  transcribed automatically, within the daily limit.") and when the feed was last
  checked.
- **Add podcast**: search the podcast directory or paste an RSS link. After
  adding, the sheet shows the import progress (checked every 5 seconds) or why it
  failed, and the episode list refreshes when the import completes. New podcasts
  arrive with their episode list only; transcribe the episodes you want to ask
  about, or turn on automatic transcription.
- **Episode details**: summary, chapters and episode notes. Tap a chapter to play
  from its start.
- Voice questions: tap to record and tap again to send, or hold while speaking and
  release to send. **Cancel recording** discards it. In **This episode** scope
  the episode id is sent with the recording so names from the episode are spelled
  correctly. Optional spoken answers; **Stop spoken answer** skips the rest.
- Transcript-grounded answers with full source excerpts and **Listen from**
  controls, which start at the beginning of the cited sentence (`playFromSec`,
  falling back to the passage start). Errors are short messages, for example
  "Too many requests, try again in 12 s." for a rate limit.

## Run

Start the API and worker from the repository root first; see the root README.
Then, from this directory:

```bash
flutter pub get
flutter run
```

Sign in with an account created by an administrator (`npm run user:create` in
`apps/api`, or `POST /v1/admin/users`).

### Build settings (`--dart-define`)

| Name | Default | Purpose |
| --- | --- | --- |
| `API_BASE_URL` | `http://10.0.2.2:4000` (Android emulator), `http://localhost:4000` (iOS simulator) | API address. Relative `playbackUrl`s are resolved against it. |
| `API_KEY` | none | Optional service token (the server's `APP_API_KEY`). With it the app skips signing in and sends it as `Authorization: Bearer <key>`. Without it every build, debug included, shows the sign-in screen. |

To use a physical device, supply the server's reachable address:

```bash
flutter run --dart-define=API_BASE_URL=http://YOUR_COMPUTER_LAN_IP:4000
```

A service key is meant for scripts and testing, not for distributed builds:
anything compiled into an app can be extracted from it. If the server rejects it,
the app shows the sign-in screen. **Sign out** while using it also shows the
sign-in screen.

Allow microphone access when prompted to record a voice question. Typed questions
work without microphone permission. Use the speaker icon beside the voice control
to turn spoken answers on or off.

### Platform notes

- **iOS**: `UIBackgroundModes` contains `audio`, and the audio session is set up
  for spoken audio (`AVAudioSessionModeSpokenAudio`). Recording switches it to
  play-and-record; the app switches it back after each recording. iOS allows
  local networking and includes the microphone and local-network permission
  descriptions.
- **Android**: `MainActivity` extends `AudioServiceActivity`, and the manifest
  declares the `audio_service` media playback service, the media button receiver
  and the `WAKE_LOCK`, `FOREGROUND_SERVICE` and
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permissions. The notification uses a
  monochrome icon (`res/drawable/ic_stat_podcast.xml`). Auto backup is off
  because the encrypted session token cannot be restored on another device.
  Debug/profile builds allow HTTP for local development; use an HTTPS API
  endpoint in an Android release build. The minimum SDK is 24.

The app identifier is `io.github.jacobstarheim.aipodcast` on both platforms.

## Code layout

- `lib/main.dart`: wiring (API client, session, media session) and the sign-in
  gate, which builds a fresh `PodcastController` for each signed-in session.
- `lib/session_controller.dart`, `lib/session_store.dart`: sign-in, sign-out,
  `401` handling and the secure token storage.
- `lib/podcast_controller.dart` with `lib/controller/`: the home screen's state,
  split into `library.dart` (episode list, selection, transcription, daily
  limit), `playback.dart` (player, positions, lock screen commands, renewing
  links) and `conversation.dart` (questions, streamed and spoken answers, stored
  conversations).
- `lib/podcast_api.dart`: the HTTP client, including the server-sent event parser
  for streamed answers.
- `lib/audio_output.dart`, `lib/media_session.dart`: two `just_audio` players (the
  episode, and spoken answers) and the `audio_service` handler that mirrors only
  the episode player to the lock screen, so asking while listening (pause,
  answer, resume) keeps working.
- `lib/conversation_store.dart`, `lib/playback_position_store.dart`: what is kept
  on the device in shared preferences.

## Checks

```bash
flutter analyze
flutter test
flutter build apk --debug
```

Tests use fakes for the API, recorder, audio player, secure storage and shared
preferences. They cover the HTTP contract (bearer token, query parameters,
request bodies, multipart fields, error parsing including `Retry-After` and the
`code` field), parsing of the answer stream (chunks that split lines, JSON or
UTF-8 characters, error events, refusals after streamed text), relative
`playbackUrl`s, defensive model parsing, signing in and out, `401` handling and
token storage, the service key, play/pause/seek and remembered positions,
renewing expired playback links, `playFromSec`, lock screen commands and the
media session wiring, position-aware questions and resuming playback,
conversation history, scopes and stored conversations, transcription and import
polling, the daily limit, automatic transcription, the add-podcast flow, chapter
playback, and layouts (including sign-in) on a 320×568 screen with large text and
an open keyboard. Native recording, background playback and lock screen controls
still require a device or simulator test.
