# Verification record

Checks performed on 2026-10-26 against the `feat/real-podcast-readiness` working
tree. API keys remain in ignored backend environment files.

## Automated checks

| Check | Result |
| --- | --- |
| `npm run build` | Passed: shared types, API, and worker |
| `npm test` | Passed: 70 API tests and 70 worker tests (database suites skipped) |
| `npm run test:db` | Passed: migrations applied to a fresh database twice (second run a no-op); 6 API and 5 worker database tests against PostgreSQL 16 with pgvector 0.8.7 |
| Flutter analysis | Clean |
| Full `flutter test` suite | Passed: 169 tests (63 before this revision) |

The database suites use the real SQL: feed upserts, job claiming with
`SKIP LOCKED`, stale-job recovery, attempt limits, transcript and chapter
storage, filtered HNSW search, keyword search, and pagination. Model calls and
network requests in unit tests are simulated.

Migration `002` was also applied to a copy of the existing local database (one
ready demo episode, two transcript segments) and then to the database itself,
after a `pg_dump` backup. Data was preserved.

## Real audio without model calls

One episode of a public feed (Hard Fork, 60.2 minutes, 55 MB MP3 behind six
tracking redirects) was downloaded and segmented with the worker code, without
transcription:

- Download streamed to disk in 2.7 seconds; the redirect chain needed a higher
  redirect limit (now 15), which this test found.
- 180 clips of 10.2–29.8 seconds (median 20.0), contiguous boundaries, cut in
  4.1 seconds.
- With the chosen silence settings (−30 dB, 0.2 s), 174 of 181 planned cuts fall
  in a pause; the previous setting (−35 dB, 0.3 s) managed 144 of 178.

Adding that feed through `POST /v1/sources` imported its episode list (the
public feed lists three episodes) with artwork and durations, and transcribed
nothing.

## Live checks with real models

`npm run test:live` passed all eight checks against the running database,
worker, API, and configured OpenAI models (the demo episode was already ready,
so it was not transcribed again):

1. API and local demo server connectivity.
2. HTTP Range support for seeking in episode audio.
3. RSS import, episode readiness, transcription, and embeddings.
4. Transcription of a recorded sensor question.
5. An answer identifying 24 sensors with valid citation times.
6. Refusal to supply the captain's name, which is absent from the recording.
7. Playable WAV output for the English answer.
8. Playable WAV output for Norwegian text containing the number 24.

A metadata-only import of the demo feed then backfilled the episode's summary
and one chapter with the real model. Questions against the real models:

| Question | Result |
| --- | --- |
| "Hvor mange sensorer har skipet?" (Norwegian, English episode) | "Skipet har 24 sensorer.", cites 0:00–0:30 |
| "Og hvor reiser det fra?" with the previous turn as history | "Det reiser fra Tromsø.", cites 0:00–0:30 |
| "What did they just say?" at position 40 s | Summary of the passages just heard, cites both passages |
| "Hva handler episoden om?" | Norwegian overview, cites the chapter |
| "Hva heter kapteinen på Aurora?" | Refused (`insufficient_grounded_citations`) |
| Library-wide "Which ship carries sea temperature sensors?" | "The research ship Aurora …", cites 0:00–0:30 |

The refusal text itself is English regardless of the question's language.

Rewriting the question takes 2.1–2.4 seconds with the configured model, longer
than the answer itself (1.2–1.6 seconds). It therefore runs in parallel with a
search for the question as asked, and a first question whose best passage is
clearly similar is answered without it. Measured end to end through the API:

| Question | Time |
| --- | --- |
| "How many sensors does the research ship Aurora carry?" | 1.9 s (no rewrite needed) |
| "Hvor mange sensorer har skipet?" | 3.5 s (translated) |
| "Hva handler episoden om?" | 3.8 s (overview) |

Before this change the same pipeline took 3.5–7 seconds per question; the
previous revision, without rewriting, took about 2 seconds.

## Answer quality on a real episode

The Hard Fork episode "Why No One Can Look Away From Elizabeth Holmes"
(67 minutes, English) was transcribed through the normal app flow
(`POST /v1/episodes/:id/transcribe`).

- Download, segmentation, transcription of 199 clips (12–30 s, average
  20.3 s), embeddings, summary and ten chapters took 1 minute 48 seconds.
- The transcript reads well: no words were cut at clip boundaries. Names are
  the weak spot. Erin Griffith appears as "Aaron Griffith" in three passages,
  John Carreyrou once as "John Carew", Deborah Kamin as "Deborah Camen". The
  summary consequently calls "Aaron Griffith" a host.

`scripts/eval/datasets/hard-fork-holmes.json` holds 29 questions with answers
and times taken from the transcript: 12 factual, 4 in Norwegian, 3 follow-ups
(one in Norwegian), 3 overview, 2 asked at a playback position, 3 that the
episode cannot answer, and 2 across the whole library.

| Configuration | Passed | Correct answers | Citation in the right place | Wrong refusals | Median / p90 latency |
| --- | --- | --- | --- | --- | --- |
| As merged (6 passages, no neighbours) | 23/29 | 21/26 | 16/22 | 4 | 3.9 s / 4.9 s |
| + neighbouring passages, planner and timeout fixes | 27–28/29 (3 runs) | 24–25/26 | 20–21/22 | 1–2 | 3.2–3.4 s / 4.4–4.7 s |
| + 10 passages instead of 6 (new default) | 29/29 (3 runs) | 26/26 | 22/22 | 0 | 3.3 s / 4.0–4.6 s |

All three unanswerable questions were refused in every run. One case was a
dataset error (its window was too narrow) and was corrected after the first
run; the first row counts it as failed.

What the failures showed:

- Similarity scores across a one-hour conversation are flat (about 0.5–0.6),
  so with six passages the right one was often just outside the cut-off.
- Passages are embedded with their neighbours' text, but the answer model
  only saw the passage itself. The search could find the right spot while the
  model never saw the sentence (for example "selling some of its assets to
  Walt Disney"). The neighbours are now passed as separate citable passages.
- The question planner sometimes added names that were not in the question
  ("The Inventor"); it is now told not to.
- The answer model once wrote a chunk number ("[3]") into the answer; such
  markers are removed and the model is told not to write them.
- One question took 104 seconds, most likely a stalled model request retried
  under the old 60-second timeout. Interactive calls now time out after 25
  seconds with one retry.

The results describe one English talk show and questions written from its
transcript. They do not establish quality for other languages, music-heavy
episodes, or questions phrased very differently.

## Mobile app

The app was built for and run on an **iPhone 17 simulator (iOS 26.5)** against
the running API, worker and demo server, with the debug app key:

| Flow | Observed result |
| --- | --- |
| Library | Real data from the API: Hard Fork episodes with artwork, duration and "Not transcribed", the Aurora demo "Ready to ask", podcast filter chips and "Only ready" |
| Real episode playback | A one-hour Hard Fork episode streamed through its six-redirect URL; play, pause, resume and seeking to 30:03 with the progress bar worked |
| Saved position | After terminating and relaunching the app, the episode showed **Resume** at the saved position |
| Ask while listening | With the demo playing, a typed "What did they just say?" paused playback at 0:22, sent the position, showed the answer with passages, read it aloud, and playback resumed |
| Follow-up | "And how long does it last?" was answered "It lasts three days." using the conversation |
| Citation playback | **Listen from 0:30** played and highlighted the cited passage |
| Add podcast | Searching "hard fork" listed Apple Podcasts results with artwork; the podcast already in the library was marked with its episode count |

Not exercised in the simulator: recording a spoken question (the recorder code
is unchanged), the **Transcribe** button on a real episode (it would start a paid
transcription), and adding a new podcast from the sheet (the same request was
verified through the API). Android was not run in this revision; the Android
application ID changed to `io.github.jacobstarheim.aipodcast`.

## Remaining limits

- One real episode has been transcribed and evaluated (see above); other
  podcasts, languages and audio styles have not.
- No physical iOS or Android devices have been verified.
- The demo fixture is short and controlled; the checks do not establish
  transcription quality across arbitrary podcast feeds, languages, or recordings.
- Citations identify clips of 10–30 seconds rather than individual words.
- Rate limits are per API process and per client address; the app key is shared.
- Spoken answers are rejected when the Realtime model does not read the text
  verbatim. In one of four live runs the Norwegian speech check failed this way
  ("Generated speech did not match the supplied answer") and passed on rerun.
