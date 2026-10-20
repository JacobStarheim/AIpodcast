# Verification record

Checks performed on 2026-10-20 against the current working tree. The local demo
uses a short fictional recording about the research ship Aurora, which carries
24 sensors. API keys remain in ignored backend environment files.

## Automated and live backend checks

| Check | Result |
| --- | --- |
| `npm run build` | Passed: shared types, API, and worker |
| `npm test` | Passed: 40 API tests and 17 worker tests |
| Flutter analysis | Clean |
| Full `flutter test` suite | Passed: 63/63 tests |
| `npm run test:live` | Passed: all eight checks against real services |

The live smoke test uses the running PostgreSQL database, worker, API, and
configured OpenAI models. It does not insert a prepared transcript or embeddings
and does not substitute model responses. It checks:

1. API and local demo server connectivity.
2. HTTP Range support for seeking in episode audio.
3. RSS import, episode readiness, transcription, and embeddings.
4. Transcription of a recorded sensor question.
5. An answer identifying 24 sensors with valid citation times.
6. Refusal to supply the captain's name, which is absent from the recording.
7. Playable WAV output for the English answer.
8. Playable WAV output for Norwegian text containing the number 24.

All eight live checks passed with the final API configuration.
The most recent report is `.local/smoke-report.json`; generated recordings and
speech output are in `.local/demo/`. Repeated smoke runs reuse an already ready
demo episode. API unit tests use controlled service responses; the live test
provides separate evidence for real model calls.

Citation windows are approximately 30 seconds, based on the actual audio clips
sent for transcription. They are not word-level alignments.

## Interface refresh

The refreshed app adds a warm theme and custom local artwork, search across the
loaded episode library, episode details and play/stop controls, a pinned question
composer with suggestions, and tap-to-record/tap-to-send alongside hold recording
and cancellation. Answers keep the latest question visible and use clearer
progress and error messages. Source excerpts open in a sheet with **Listen from**
playback.

The 63 Flutter tests cover questions and playback, library retry, microphone
semantics, and the library/composer at 320×568, 1.8× text scale, and a 260-pixel
keyboard inset. Native checks on the refreshed Android and iOS builds passed
library navigation, episode playback, typed Q&A, and real voice Q&A.

Current UI evidence is under `.local/qa/ui-ios/` (including `home.jpg`) and
`.local/qa/ui-android/`. The final builds expose episode rows and **Listen from**
as accessible button actions. Selecting an episode closes the library sheet.
Analysis reports zero issues; the latest 11 widget tests, including accessibility
assertions, passed within the 63-test suite.

## iOS simulator

Target: **iPhone 17 simulator, iOS 26.5**.

| Flow | Observed result |
| --- | --- |
| Build and launch | Refreshed app source built and launched successfully |
| Library and episode controls | Library navigation, episode details, and original-audio playback worked |
| Typed question | Sensor question returned an answer identifying 24 sensors |
| Spoken answer | Real synthesis reached native `Speaking`, then returned to `Idle` without a player error |
| Citation | Original episode playback started and exposed the stop control |
| Unsupported question | Captain question produced a refusal |
| Native voice question | Both tap and hold recording captured the known question through the simulator microphone; upload and `gpt-transcribe` produced the question, followed by a grounded 24-sensor answer, native TTS, and return to idle |
| Source excerpt and accessibility | Episode rows and **Listen from 0:00** expose button actions; selection closes the library, the excerpt sheet shows full source text, and source playback starts and stops |
| Silent recording | A three-second native AAC sample returned an empty transcript; the app displayed a recoverable message and returned to `Hold to talk` without a codec error |
| First microphone permission | With permission reset, releasing the record control while the permission dialog was open, then granting permission, returned cleanly to `Hold to talk` without an error or a near-empty upload |

The playback evidence is the observed UI/player state and absence of reported
player errors. No speaker waveform or acoustic output was measured.

For the native voice check, recording was started through the app UI,
`.local/demo/question.wav` was played using macOS `afplay` while the simulator
microphone was active, and the recording was sent through the UI. This used the
actual recorder and the host-audio-to-simulator-microphone path, without a mocked
recorder or gRPC audio injection.

The final native question flow produced “How many sensors does the research ship
Aurora carry?”, a grounded 24-sensor answer, and spoken playback returning to `Idle`.
Current UI screenshots are `.local/qa/ui-ios/home.jpg`,
`.local/qa/ui-ios/library.jpg`, and `.local/qa/ui-ios/answer.jpg`.
The backend live test additionally verifies the recorded question directly through
the API.

## Android

The refreshed APK passed these native flows:

| Flow | Observed result |
| --- | --- |
| Typed question | Real backend returned the correct 24-sensor answer |
| Library and episode controls | Library navigation, details, and original-audio playback worked |
| Native voice question | Both tap and hold recording captured the known question through the emulator microphone; native AAC upload, `gpt-transcribe`, and Q&A returned the correct answer with citations |
| Spoken answer | Speaker playback completed and returned to idle |
| Citation | Original-episode playback and stopping worked |
| Accessibility | Final native UI XML identifies episode rows and **Listen from** as buttons |
| Unsupported question | Captain question produced a refusal |
| First microphone permission | Releasing while the permission dialog was open, then granting permission, returned cleanly without uploading an unfinished recording |
| Crashes and layout | Final logs contained no crash, layout, or unhandled errors |

The known question entered the emulator microphone through its gRPC audio input
while the real app recorder was active. The recorder, upload, and model calls were
not mocked. Both voice gestures were checked before the final accessibility-only
adjustment; the final APK passed library selection, typed Q&A, and source play/stop.
Current evidence is `.local/qa/ui-android/results.json`,
`.local/qa/ui-android/22-final-home.png`, and
`.local/qa/ui-android/20-final-answer-accessibility.png`.

## Remaining limits

- No physical iOS or Android devices have been verified.
- The included fixture is short and controlled; the checks do not establish
  transcription quality across arbitrary podcast feeds, languages, or recordings.
- Citations identify roughly 30-second audio clips rather than individual words.
