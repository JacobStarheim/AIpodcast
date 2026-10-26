import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_voice_ai/main.dart';
import 'package:podcast_voice_ai/models.dart';
import 'package:podcast_voice_ai/playback_position_store.dart';
import 'package:podcast_voice_ai/podcast_controller.dart';
import 'package:podcast_voice_ai/presentation/add_podcast_sheet.dart';
import 'package:podcast_voice_ai/presentation/library_sheet.dart';

import 'fakes.dart';

void main() {
  testWidgets('typed question displays an answer and playable citations',
      (tester) async {
    final audio = FakeAudioOutput();
    final controller = PodcastController(
      api: FakeApi(),
      recorder: FakeRecorder(),
      audioOutput: audio,
    )..setReadAnswersAloud(false);
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('question-input')), 'What was discussed?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask-question')));
    await tester.pumpAndSettle();
    expect(find.text('From this episode'), findsOneWidget);
    expect(find.text('The host discussed architecture and citations.'),
        findsOneWidget);
    final citation = find.text('Listen from 2:00');
    await tester.ensureVisible(citation);
    await _expectAccessibleButton(tester, citation, 'Listen from 2:00');
    await tester.tap(citation);
    await tester.pumpAndSettle();
    expect(audio.lastEpisodeUrl, 'https://example.com/ep1.mp3');
    expect(audio.lastSeek, const Duration(seconds: 120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screen and large text keep the composer usable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetViewInsets);
    final controller = PodcastController(
      api: FakeApi(),
      recorder: FakeRecorder(),
      audioOutput: FakeAudioOutput(),
    )..setReadAnswersAloud(false);
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    await controller.submitTypedQuestion('Question');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('From this episode'));
    expect(tester.takeException(), isNull);

    final input = find.byKey(const ValueKey('question-input'));
    expect(input.hitTestable(), findsOneWidget);
    await tester.tap(input);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    await tester.enterText(input, 'A follow-up question');
    expect(input.hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-question')).hitTestable(),
        findsOneWidget);
    expect(tester.getBottomRight(input).dy, lessThanOrEqualTo(308));
    expect(tester.takeException(), isNull);
  });

  testWidgets('blank questions are disabled and the keyboard sends a question',
      (tester) async {
    final api = FakeApi();
    final controller = PodcastController(
      api: api,
      recorder: FakeRecorder(),
      audioOutput: FakeAudioOutput(),
    )..setReadAnswersAloud(false);
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('question-input'));
    final submit = find.byKey(const ValueKey('ask-question'));

    await tester.enterText(input, '   ');
    await tester.pump();
    final semantics = tester.ensureSemantics();
    try {
      expect(
          tester
              .getSemantics(submit)
              .getSemanticsData()
              .flagsCollection
              .isEnabled,
          Tristate.isFalse);
    } finally {
      semantics.dispose();
    }
    await tester.tap(submit);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(api.questionCalls, 0);

    await tester.enterText(input, 'What was discussed?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(api.questionCalls, 1);
    expect(controller.lastQuestionText, 'What was discussed?');
    expect(find.text('The host discussed architecture and citations.'),
        findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the microphone records then sends the question',
      (tester) async {
    final api = FakeApi();
    final recorder = FakeRecorder();
    final controller = PodcastController(
      api: api,
      recorder: recorder,
      audioOutput: FakeAudioOutput(),
    )..setReadAnswersAloud(false);
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    final microphone = find.byKey(const ValueKey('push-to-talk'));
    await tester.tap(microphone);
    await tester.pump(const Duration(milliseconds: 200));
    expect(recorder.started, isTrue);
    expect(controller.voiceState, VoiceState.recording);
    expect(api.transcriptionCalls, 0);

    await tester.tap(microphone);
    await tester.pumpAndSettle();
    expect(recorder.started, isFalse);
    expect(recorder.stopCalls, 1);
    expect(api.transcriptionCalls, 1);
    expect(api.questionCalls, 1);
    expect(controller.voiceState, VoiceState.idle);
    expect(find.text('From this episode'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'microphone announces when the episode is not ready for questions',
      (tester) async {
    final recorder = FakeRecorder();
    final controller = PodcastController(
      api: FakeApi(),
      recorder: recorder,
      audioOutput: FakeAudioOutput(),
    );
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(PodcastVoiceApp(controller: controller));
      await tester.pumpAndSettle();
      final microphone = find.byKey(const ValueKey('push-to-talk'));
      expect(
          tester
              .getSemantics(microphone)
              .getSemanticsData()
              .flagsCollection
              .isEnabled,
          Tristate.isTrue);
      await controller.selectEpisode('pending');
      await tester.pumpAndSettle();
      expect(
          tester
              .getSemantics(microphone)
              .getSemanticsData()
              .flagsCollection
              .isEnabled,
          Tristate.isFalse);
      await tester.tap(microphone);
      await tester.pump();
      expect(recorder.started, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('library search filters episodes and selects the chosen episode',
      (tester) async {
    final api = FakeApi();
    final controller = PodcastController(
      api: api,
      recorder: FakeRecorder(),
      audioOutput: FakeAudioOutput(),
    );
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    await controller.loadMoreEpisodes();
    await tester.tap(find.byTooltip('Browse episodes'));
    await tester.pumpAndSettle();
    expect(find.text('Your library'), findsOneWidget);
    expect(find.text('Episode 1'), findsOneWidget);
    expect(find.text('Episode 2'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('episode-search')), 'Episode 2');
    await tester.pump();
    expect(find.text('Episode 1'), findsOneWidget,
        reason: 'the server search waits until typing pauses');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(api.lastListQuery, 'Episode 2');
    expect(find.text('Episode 1'), findsNothing);
    final episode = find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'Episode 2');
    await _expectAccessibleButton(tester, episode, 'Episode 2');
    await tester.tap(episode);
    await tester.pumpAndSettle();
    expect(controller.selectedEpisode?.episode.id, 'ep2');
    expect(find.text('Your library'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library search stays usable with large text and a keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetViewInsets);
    final controller = PodcastController(
      api: FakeApi(),
      recorder: FakeRecorder(),
      audioOutput: FakeAudioOutput(),
    );
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Browse episodes'));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('episode-search'));
    await tester.tap(search);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    await tester.enterText(search, 'Episode');
    expect(search.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(search).dy, lessThanOrEqualTo(308));
    expect(tester.takeException(), isNull);
  });

  testWidgets('library shows a recoverable error when loading more fails',
      (tester) async {
    final api = FakeApi();
    final controller = PodcastController(
      api: api,
      recorder: FakeRecorder(),
      audioOutput: FakeAudioOutput(),
    );
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Browse episodes'));
    await tester.pumpAndSettle();
    api.throwOnList = true;
    final loadMore = find.text('Load more episodes');
    await tester.ensureVisible(loadMore);
    await tester.tap(loadMore);
    await tester.pumpAndSettle();
    expect(
        find.text(
            'We couldn’t update your library. Check your connection and try again.'),
        findsOneWidget);
    expect(find.textContaining('network failure'), findsNothing);
    expect(controller.episodes, hasLength(1));

    api.throwOnList = false;
    final retry = find.text('Try again');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(controller.episodes, hasLength(2));
    expect(
        find.textContaining('We couldn’t update your library'), findsNothing);
    await tester.ensureVisible(find.text('Episode 2'));
    expect(find.text('Episode 2').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported questions have a human-readable response',
      (tester) async {
    final api = FakeApi()..refuseAnswer = true;
    final controller = PodcastController(
      api: api,
      recorder: FakeRecorder(),
      audioOutput: FakeAudioOutput(),
    );
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('question-input')),
        'What is the captain called?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask-question')));
    await tester.pumpAndSettle();
    expect(find.text('Not covered in this episode'), findsOneWidget);
    expect(
        find.textContaining('insufficient_retrieval_confidence'), findsNothing);
    expect(find.text('Listen from 2:00'), findsNothing);
    expect(api.synthesisCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the episode can play without first asking a question',
      (tester) async {
    final audio = FakeAudioOutput();
    final controller = PodcastController(
      api: FakeApi(),
      recorder: FakeRecorder(),
      audioOutput: audio,
    );
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    await _expectAccessibleButton(
        tester, find.byKey(const ValueKey('play-episode')), 'Play episode');
    await tester.tap(find.byKey(const ValueKey('play-episode')));
    await tester.pumpAndSettle();
    expect(audio.lastEpisodeUrl, 'https://example.com/ep1.mp3');
    expect(audio.lastSeek, Duration.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'system pointer cancellation stops an accepted hold-to-talk gesture',
      (tester) async {
    final api = FakeApi();
    final recorder = FakeRecorder();
    final controller = PodcastController(
        api: api, recorder: recorder, audioOutput: FakeAudioOutput());
    await tester.pumpWidget(PodcastVoiceApp(controller: controller));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('push-to-talk'));
    await tester.ensureVisible(button);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(controller.voiceState, VoiceState.recording);
    expect(recorder.started, true);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(recorder.started, false);
    expect(recorder.stopCalls, 1);
    expect(api.transcriptionCalls, 0);
    expect(controller.voiceState, VoiceState.idle);
  });
  group('player', () {
    testWidgets('shows elapsed and total time, pauses, resumes and seeks',
        (tester) async {
      final audio = FakeAudioOutput();
      final controller = await _pumpApp(tester, audio: audio);
      expect(_text(tester, 'playback-elapsed'), '0:00');
      expect(_text(tester, 'playback-total'), '15:00');

      final play = find.byKey(const ValueKey('play-episode'));
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(find.text('Pause'), findsOneWidget);
      audio.emit(const Duration(seconds: 65),
          duration: const Duration(minutes: 16));
      await tester.pump();
      expect(_text(tester, 'playback-elapsed'), '1:05');
      expect(_text(tester, 'playback-total'), '16:00');

      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(audio.pauseCalls, 1);
      expect(find.text('Resume'), findsOneWidget);

      final slider = find.byKey(const ValueKey('playback-slider'));
      await tester.ensureVisible(slider);
      await tester.tapAt(tester.getCenter(slider));
      await tester.pumpAndSettle();
      expect(audio.lastSeek!.inSeconds, closeTo(480, 10));
      expect(controller.selectedProgress.value.position.inSeconds,
          closeTo(480, 10));
      expect(controller.playerStatus, PlayerStatus.paused);

      await tester.ensureVisible(play);
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(audio.lastSeek!.inSeconds, closeTo(480, 10));
      expect(controller.isPlayingEpisode, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('resumes from a remembered position', (tester) async {
      final audio = FakeAudioOutput();
      final controller = PodcastController(
        api: FakeApi(),
        recorder: FakeRecorder(),
        audioOutput: audio,
        positionStore: MemoryPlaybackPositionStore()
          ..positions['ep1'] = const Duration(minutes: 3, seconds: 20),
      );
      await tester.pumpWidget(PodcastVoiceApp(controller: controller));
      await tester.pumpAndSettle();
      expect(_text(tester, 'playback-elapsed'), '3:20');
      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('play-episode')));
      await tester.pumpAndSettle();
      expect(audio.lastSeek, const Duration(minutes: 3, seconds: 20));
    });
  });

  group('questions about what was just heard', () {
    testWidgets(
        'the composer shows the position, sends it, and resumes playback',
        (tester) async {
      final api = FakeApi();
      final audio = FakeAudioOutput();
      final controller = await _pumpApp(tester, api: api, audio: audio);
      expect(find.byKey(const ValueKey('question-position')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('play-episode')));
      await tester.pumpAndSettle();
      audio.emit(const Duration(minutes: 12, seconds: 34));
      await tester.pump();
      expect(find.text('About 12:34'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('question-input')), 'What did she mean?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(api.lastPositionSec, 754);
      expect(find.text('YOUR QUESTION · AT 12:34'), findsOneWidget);
      expect(audio.events, containsAllInOrder(['pause', 'play ${audio.lastEpisodeUrl}@754000']));
      expect(controller.playerStatus, PlayerStatus.playing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dismissing the position chip asks without it',
        (tester) async {
      final api = FakeApi();
      final audio = FakeAudioOutput();
      await _pumpApp(tester, api: api, audio: audio);
      await tester.tap(find.byKey(const ValueKey('play-episode')));
      await tester.pumpAndSettle();
      audio.emit(const Duration(seconds: 90));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('play-episode')));
      await tester.pumpAndSettle();
      expect(find.text('About 1:30'), findsOneWidget);

      await tester.tap(find.byTooltip('Ask without the playback position'));
      await tester.pumpAndSettle();
      expect(find.text('About 1:30'), findsNothing);
      await tester.enterText(
          find.byKey(const ValueKey('question-input')), 'What is it about?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(api.questionCalls, 1);
      expect(api.lastPositionSec, isNull);
      expect(find.text('YOUR QUESTION'), findsOneWidget);
    });
  });

  group('conversation', () {
    testWidgets('follow-up answers stack and New conversation clears them',
        (tester) async {
      final api = FakeApi();
      await _pumpApp(tester, api: api);
      final input = find.byKey(const ValueKey('question-input'));
      await tester.enterText(input, 'First question');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      await tester.enterText(input, 'Second question');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.text('First question'), findsOneWidget);
      expect(find.text('Second question'), findsOneWidget);
      expect(find.text('From this episode'), findsNWidgets(2));
      expect(api.lastHistory.single.question, 'First question');

      final newConversation = find.byKey(const ValueKey('new-conversation'));
      await tester.ensureVisible(newConversation);
      await _expectAccessibleButton(
          tester, newConversation, 'New conversation');
      await tester.tap(newConversation);
      await tester.pumpAndSettle();
      expect(find.text('First question'), findsNothing);
      expect(find.text('Follow your curiosity.'), findsOneWidget);
      await tester.enterText(input, 'Third question');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(api.lastHistory, isEmpty);
    });

    testWidgets(
        'the whole library scope answers across episodes and plays other episodes',
        (tester) async {
      final api = FakeApi()..citationEpisodeId = 'ep2';
      final audio = FakeAudioOutput();
      await _pumpApp(tester, api: api, audio: audio);
      final library = find.byKey(const ValueKey('scope-library'));
      await tester.ensureVisible(library);
      await _expectAccessibleButton(tester, library, 'Whole library');
      await tester.tap(library);
      await tester.pumpAndSettle();
      expect(find.text('Ask across your library…'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('question-input')), 'Common themes?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(api.askedWithEpisode, isFalse);
      expect(find.text('From your library'), findsOneWidget);
      expect(find.text('Episode ep2'), findsOneWidget);

      final listen = find.text('Listen from 2:00');
      await tester.ensureVisible(listen);
      await tester.tap(listen);
      await tester.pumpAndSettle();
      expect(audio.lastEpisodeUrl, 'https://example.com/ep2.mp3');
      expect(find.text('Pause'), findsOneWidget,
          reason: 'the playing citation can be paused');
      expect(find.text('Playing: Episode ep2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('library', () {
    testWidgets(
        'shows duration and status, and a pending episode can be transcribed',
        (tester) async {
      final api = FakeApi()
        ..pageSize = 5
        ..library = [
          demoEpisode('ep1', title: 'Episode 1'),
          demoEpisode('ep2',
              title: 'Episode 2', status: TranscriptionStatus.pending),
          demoEpisode('ep3',
              title: 'Episode 3',
              status: TranscriptionStatus.failed,
              transcriptionError: 'Audio download failed',
              imageUrl: 'https://img.example/ep3.jpg'),
        ];
      final controller = await _pumpApp(tester, api: api);
      await tester.tap(find.byTooltip('Browse episodes'));
      await tester.pumpAndSettle();
      expect(find.text('Not transcribed'), findsOneWidget);
      expect(find.text('Transcription failed'), findsOneWidget);
      expect(find.text('Audio download failed'), findsOneWidget);
      expect(find.textContaining(' · 15 min'), findsNWidgets(3));
      expect(find.text('Try again'), findsOneWidget);

      final transcribe = find.byKey(const ValueKey('transcribe-ep2'));
      await _expectAccessibleButton(tester, transcribe, 'Transcribe Episode 2');
      api.statusSequence['ep2'] = [
        TranscriptionStatus.processing,
        TranscriptionStatus.ready,
      ];
      await tester.tap(transcribe);
      await tester.pump();
      expect(api.transcribeCalls, 1);
      expect(find.text('Queued'), findsOneWidget);
      expect(find.byKey(const ValueKey('transcribe-ep2')), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Transcribing'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Transcribing'), findsNothing);
      expect(
          controller.episodes.firstWhere((e) => e.id == 'ep2').transcriptionStatus,
          TranscriptionStatus.ready);
      expect(tester.takeException(), isNull);
    });

    testWidgets('filters by podcast and readiness on the server',
        (tester) async {
      final api = FakeApi()
        ..sources = [demoSource('src1', 'Demo'), demoSource('src2', 'Other')];
      final controller = await _pumpApp(tester, api: api);
      await tester.tap(find.byTooltip('Browse episodes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-source-src2')));
      await tester.pumpAndSettle();
      expect(api.lastListSourceId, 'src2');
      expect(find.text('No episodes match these filters.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('filter-all-podcasts')));
      await tester.pumpAndSettle();
      expect(api.lastListSourceId, isNull);
      await tester.tap(find.byKey(const ValueKey('filter-ready')));
      await tester.pumpAndSettle();
      expect(api.lastListStatuses, {TranscriptionStatus.ready});
      expect(controller.episodes.map((episode) => episode.id), ['ep1']);
      expect(find.text('No episodes match these filters.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the selected episode card offers transcription',
        (tester) async {
      final api = FakeApi()
        ..library = [
          demoEpisode('ep1', status: TranscriptionStatus.pending),
        ];
      final controller = await _pumpApp(tester, api: api);
      expect(controller.isEpisodeReady, isFalse);
      final transcribe = find.byKey(const ValueKey('transcribe-selected'));
      await _expectAccessibleButton(tester, transcribe, 'Transcribe episode');
      await tester.tap(transcribe);
      await tester.pump();
      expect(api.transcribeCalls, 1);
      expect(find.textContaining('Transcription is queued'), findsOneWidget);
    });
  });

  group('add podcast', () {
    testWidgets('search, add and follow the import', (tester) async {
      final api = FakeApi()
        ..searchResults = [
          PodcastSearchResult(
              title: 'History Hour',
              author: 'BBC',
              genre: 'History',
              feedUrl: 'https://feeds.example/hh.xml'),
        ];
      await _pumpApp(tester, api: api);
      api.sourceSnapshots.addAll([
        [
          demoSource('src1', 'Demo'),
          demoSource('src-new', 'History Hour',
              rssUrl: 'https://feeds.example/hh.xml',
              job: IngestJobStatus.processing,
              episodes: 0),
        ],
        [
          demoSource('src1', 'Demo'),
          demoSource('src-new', 'History Hour',
              rssUrl: 'https://feeds.example/hh.xml', episodes: 25),
        ],
      ]);
      final listCalls = api.listCalls;
      await tester.tap(find.byTooltip('Browse episodes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add podcast'));
      await tester.pumpAndSettle();
      expect(find.text('Add a podcast'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('podcast-search')), 'History');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(api.searchQueries, ['History']);
      expect(find.text('History Hour'), findsOneWidget);
      expect(find.text('BBC · History'), findsOneWidget);

      final add = find.byKey(const ValueKey('add-https://feeds.example/hh.xml'));
      await _expectAccessibleButton(tester, add, 'Add History Hour');
      await tester.tap(add);
      await tester.pump();
      expect(api.addRequests.single.rssUrl, 'https://feeds.example/hh.xml');
      expect(api.addRequests.single.name, 'History Hour');
      expect(find.text('Waiting to import episodes…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Importing episodes…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('25 episodes in your library'), findsOneWidget);
      expect(api.listCalls, greaterThan(listCalls));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a pasted RSS link is checked and added', (tester) async {
      final api = FakeApi();
      final controller = await _pumpApp(tester, api: api);
      showAddPodcastSheet(
          tester.element(find.byType(PodcastHomePage)), controller.sources);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('paste-rss')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('rss-url'));
      await tester.enterText(field, 'feeds.example/show');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('add-rss')));
      await tester.pumpAndSettle();

      expect(api.addRequests, isEmpty);
      expect(find.textContaining('http://'), findsOneWidget);

      await tester.enterText(field, 'https://feeds.example/show.xml');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('add-rss')));
      // The queued import shows a spinner, so the sheet never settles.
      await tester.pump();
      await tester.pump();
      expect(api.addRequests.single.rssUrl, 'https://feeds.example/show.xml');
      expect(find.text('Waiting to import episodes…'), findsOneWidget);
    });
  });

  testWidgets('episode details show the summary and chapters that play',
      (tester) async {
    final api = FakeApi();
    api.details['ep1'] = _chapteredEpisode();
    final audio = FakeAudioOutput();
    final controller = await _pumpApp(tester, api: api, audio: audio);
    await tester.tap(find.byTooltip('Episode details'));
    await tester.pumpAndSettle();
    expect(find.text('SUMMARY'), findsOneWidget);
    expect(find.text('A conversation about public budgets.'), findsOneWidget);
    expect(find.text('CHAPTERS'), findsOneWidget);
    final chapter = find.byKey(const ValueKey('chapter-c2'));
    await tester.ensureVisible(chapter);
    await _expectAccessibleButton(
        tester, chapter, 'Play from 12:34: The budget debate');
    await tester.tap(chapter);
    await tester.pumpAndSettle();
    expect(find.text('CHAPTERS'), findsNothing);
    expect(audio.lastSeek, const Duration(minutes: 12, seconds: 34));
    expect(controller.isPlayingEpisode, isTrue);
  });

  group('small screen with large text', () {
    testWidgets('playback, the position chip and the keyboard fit',
        (tester) async {
      _useSmallScreen(tester);
      final api = FakeApi()..citationEpisodeId = 'ep2';
      final audio = FakeAudioOutput();
      final controller = await _pumpApp(tester, api: api, audio: audio);
      await controller.playSelectedEpisode();
      audio.emit(const Duration(minutes: 1, seconds: 5));
      await controller.submitTypedQuestion('Question');
      controller.setScope(QuestionScope.library);
      await controller.submitTypedQuestion('Library question');
      await controller.playCitation(controller.latestResponse!.citations.first);
      controller.setScope(QuestionScope.episode);
      await tester.pumpAndSettle();
      expect(find.text('About 1:05'), findsOneWidget);
      await tester.ensureVisible(find.textContaining('Playing: '));
      expect(tester.takeException(), isNull);

      final input = find.byKey(const ValueKey('question-input'));
      await tester.tap(input);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      await tester.enterText(input, 'A follow-up question');
      expect(find.text('About 1:05').hitTestable(), findsOneWidget);
      expect(input.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(input).dy, lessThanOrEqualTo(308));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the library with filters and transcribe buttons fits',
        (tester) async {
      _useSmallScreen(tester);
      final api = FakeApi()
        ..pageSize = 5
        ..sources = [
          demoSource('src1', 'A podcast with a rather long name'),
          demoSource('src2', 'Importing', job: IngestJobStatus.processing),
        ]
        ..library = [
          demoEpisode('ep1', title: 'Episode 1'),
          demoEpisode('ep2',
              title: 'An episode with a long title that needs to wrap',
              status: TranscriptionStatus.failed,
              transcriptionError: 'The audio file could not be downloaded'),
        ];
      await _pumpApp(tester, api: api);
      await tester.tap(find.byTooltip('Browse episodes'));
      // An import in progress shows a spinner, so the sheet never settles.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('transcribe-ep2')), 100,
          scrollable: _sheetScrollable(find.byType(LibrarySheet)));
      expect(find.text('Importing: Importing episodes…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the add podcast sheet fits above the keyboard',
        (tester) async {
      _useSmallScreen(tester);
      final api = FakeApi()
        ..searchResults = [
          PodcastSearchResult(
              title: 'History of a remarkably long podcast title',
              author: 'An author with a long name',
              feedUrl: 'https://feeds.example/long.xml'),
        ];
      final controller = await _pumpApp(tester, api: api);
      showAddPodcastSheet(
          tester.element(find.byType(PodcastHomePage)), controller.sources);
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('podcast-search'));
      await tester.tap(search);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      await tester.enterText(search, 'History');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(search.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(search).dy, lessThanOrEqualTo(308));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('add-https://feeds.example/long.xml')), 100,
          scrollable: _sheetScrollable(find.byType(AddPodcastSheet)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('episode details with chapters fit', (tester) async {
      _useSmallScreen(tester);
      final api = FakeApi();
      api.details['ep1'] = _chapteredEpisode();
      await _pumpApp(tester, api: api);
      final details = find.byTooltip('Episode details');
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('chapter-c2')));
      expect(tester.takeException(), isNull);
    });
  });

}

Future<void> _expectAccessibleButton(
    WidgetTester tester, Finder finder, String label) async {
  final semantics = tester.ensureSemantics();
  try {
    await tester.pump();
    final data = tester.getSemantics(finder).getSemanticsData();
    expect(data.label, contains(label));
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
  } finally {
    semantics.dispose();
  }
}

Future<PodcastController> _pumpApp(
  WidgetTester tester, {
  FakeApi? api,
  FakeAudioOutput? audio,
}) async {
  final controller = PodcastController(
    api: api ?? FakeApi(),
    recorder: FakeRecorder(),
    audioOutput: audio ?? FakeAudioOutput(),
  )..setReadAnswersAloud(false);
  await tester.pumpWidget(PodcastVoiceApp(controller: controller));
  await tester.pumpAndSettle();
  return controller;
}

void _useSmallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.8;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.view.resetViewInsets);
}

Finder _sheetScrollable(Finder sheet) => find
    .descendant(of: sheet, matching: find.byType(Scrollable))
    .first;

String? _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data;

EpisodeDetail _chapteredEpisode() => EpisodeDetail(
      id: 'ep1',
      sourceId: 'src1',
      sourceName: 'Demo',
      guid: 'guid-ep1',
      title: 'Episode ep1',
      description: '<p>Show notes &amp; links</p>',
      publishedAt: DateTime.parse('2025-01-01T00:00:00Z'),
      audioUrl: 'https://example.com/ep1.mp3',
      transcriptionStatus: TranscriptionStatus.ready,
      durationSec: 1800,
      language: 'en',
      summary: 'A conversation about public budgets.',
      chapters: [
        Chapter(
            id: 'c1',
            title: 'Introductions',
            summary: 'The hosts introduce the guest.',
            startSec: 0,
            endSec: 754),
        Chapter(
            id: 'c2',
            title: 'The budget debate',
            summary: 'Where the money goes, and who decides.',
            startSec: 754,
            endSec: 1800),
      ],
    );
