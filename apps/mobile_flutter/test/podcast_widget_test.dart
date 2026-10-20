import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_voice_ai/main.dart';
import 'package:podcast_voice_ai/podcast_controller.dart';

import 'podcast_controller_test.dart'
    show FakeApi, FakeRecorder, FakeAudioOutput;

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
    final controller = PodcastController(
      api: FakeApi(),
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
    await tester.pumpAndSettle();
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
