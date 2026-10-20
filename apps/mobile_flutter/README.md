# Mobile App (`apps/mobile_flutter`)

Flutter iOS/Android client for asking questions about podcast transcripts.

## Features

- Searchable episode library with transcription status and **Load more episodes**.
  Search filters the episodes already loaded; load more to search further.
- Play or stop the selected episode, and open its details to read the episode notes.
- A question composer that stays within reach, keyboard submission, and suggested
  questions to get started.
- Voice questions: tap to record and tap again to send, or hold while speaking and
  release to send. Use **Cancel recording** to discard a recording.
- Transcript-grounded answers that retain your question, with full source excerpts
  and **Listen from** controls. Playback starts at the cited timestamp and continues
  through the episode; it is not limited to the displayed excerpt.
- Optional spoken answers, playback stop controls, and friendly failure messages.

Questions become available when the selected episode's transcript is ready.
The app shows the text answer even if speech generation or playback fails.

## Run

Start the API and worker from the repository root first; see the root README.
Then, from this directory:

```bash
flutter pub get
flutter run
```

The default API address is `http://10.0.2.2:4000` on an Android emulator and
`http://localhost:4000` on an iOS simulator. To use a physical device, supply the
server's reachable address instead:

```bash
flutter run --dart-define=API_BASE_URL=http://YOUR_COMPUTER_LAN_IP:4000
```

Allow microphone access when prompted to record a voice question. Typed questions
work without microphone permission. Use the speaker icon beside the voice control
to turn spoken answers on or off. Press **Stop spoken answer** or **Stop audio** to
interrupt playback.

Android debug/profile builds allow HTTP for local development. Use an HTTPS API
endpoint in an Android release build. iOS allows local networking and includes the
microphone and local-network permission descriptions.

## Checks

```bash
flutter analyze
flutter test
```

Tests cover HTTP request/response contracts, recording startup/release races,
episode selection, citation playback targets, answer/voice failures, and the typed
question widget flow. Native device recording and playback still require a
simulator or device test.
