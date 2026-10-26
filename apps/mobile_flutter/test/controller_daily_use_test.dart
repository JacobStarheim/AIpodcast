import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_voice_ai/audio_output.dart';
import 'package:podcast_voice_ai/conversation_store.dart';
import 'package:podcast_voice_ai/models.dart';
import 'package:podcast_voice_ai/playback_position_store.dart';
import 'package:podcast_voice_ai/podcast_api.dart';
import 'package:podcast_voice_ai/podcast_controller.dart';
import 'package:podcast_voice_ai/sources_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

PodcastController _controller({
  FakeApi? api,
  FakeRecorder? recorder,
  FakeAudioOutput? audio,
  PlaybackPositionStore? positions,
  ConversationStore? conversations,
}) =>
    PodcastController(
      api: api ?? FakeApi(),
      recorder: recorder ?? FakeRecorder(),
      audioOutput: audio ?? FakeAudioOutput(),
      positionStore: positions,
      conversationStore: conversations,
    )..setReadAnswersAloud(false);

Citation _citation(
        {double startSec = 120,
        double? playFromSec,
        String episodeId = 'ep1'}) =>
    Citation(
      segmentId: 'seg-$startSec',
      episodeId: episodeId,
      episodeTitle: 'Episode $episodeId',
      startSec: startSec,
      endSec: startSec + 10,
      playFromSec: playFromSec,
      text: 'cited',
      score: .9,
    );

ConversationTurn _turn(String question) => ConversationTurn(
      question: question,
      response: QaResponse(
          answerText: 'Answer to $question',
          citations: const [],
          grounded: true),
    );

void main() {
  group('Streaming answers', () {
    test('show the stage, then the text as it arrives, then the final answer',
        () async {
      final api = FakeApi()
        ..questionGate = Completer<void>()
        ..beforeDeltas = Completer<void>()
        ..beforeDone = Completer<void>();
      final controller = _controller(api: api);
      await controller.selectEpisode('ep1');
      final answering = controller.submitTypedQuestion('What was discussed?');
      await Future<void>.delayed(Duration.zero);
      expect(controller.answerStage, AnswerStage.searching);
      expect(controller.streamingAnswer.value, isEmpty);
      api.questionGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.answerStage, AnswerStage.answering);
      expect(controller.streamingAnswer.value, isEmpty);

      api.beforeDeltas!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
          controller.streamingAnswer.value, 'The host discussed architecture');
      expect(controller.conversation, isEmpty);
      expect(controller.pendingQuestion, 'What was discussed?');

      api.beforeDone!.complete();
      await answering;
      expect(controller.answerStage, isNull);
      expect(controller.streamingAnswer.value, isEmpty,
          reason: 'the final answer replaces the streamed text');
      expect(controller.conversation.single.response.answerText,
          'The host discussed architecture and citations.');
      expect(controller.pendingQuestion, isNull);
      expect(controller.voiceState, VoiceState.idle);
    });

    test('an error event shows a message and keeps the question', () async {
      final api = FakeApi()..streamError = 'model unavailable';
      final controller = _controller(api: api);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('What was discussed?');
      expect(controller.conversation, isEmpty);
      expect(controller.error?.kind, ErrorKind.question);
      expect(controller.errorMessage,
          'The answer couldn’t be finished. Please try again.');
      expect(controller.errorMessage, isNot(contains('model unavailable')));
      expect(controller.pendingQuestion, 'What was discussed?');
      expect(controller.streamingAnswer.value, isEmpty);
      expect(controller.answerStage, isNull);
      expect(controller.canAskQuestion, isTrue);
    });

    test('a refusal after streamed text replaces it and is not spoken',
        () async {
      final api = FakeApi()..refuseAfterDeltas = true;
      final audio = FakeAudioOutput();
      final controller = _controller(api: api, audio: audio)
        ..setReadAnswersAloud(true);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Who is the captain?');
      final response = controller.conversation.single.response;
      expect(response.grounded, isFalse);
      expect(response.answerText, startsWith('I do not have enough'));
      expect(controller.streamingAnswer.value, isEmpty);
      expect(api.synthesisCalls, 0);
      expect(audio.ttsCalls, 0);
    });

    test('a stream that ends without an answer is an error', () async {
      final api = FakeApi()..truncateStream = true;
      final controller = _controller(api: api);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      expect(controller.error?.kind, ErrorKind.question);
      expect(controller.conversation, isEmpty);
    });

    test('closing while streaming stops following the answer', () async {
      final api = FakeApi()..beforeDone = Completer<void>();
      final controller = _controller(api: api);
      await controller.selectEpisode('ep1');
      final answering = controller.submitTypedQuestion('Question');
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      controller.dispose();
      api.beforeDone!.complete();
      await answering;
      expect(controller.conversation, isEmpty);
    });
  });

  group('Playback links', () {
    test('the episode plays its playbackUrl, with lock screen details',
        () async {
      final audio = FakeAudioOutput();
      final api = FakeApi()
        ..library = [demoEpisode('ep1', imageUrl: 'https://img.example/1.jpg')];
      final controller = _controller(api: api, audio: audio);
      await controller.loadInitialEpisodes();
      await controller.playSelectedEpisode();
      expect(audio.lastEpisodeUrl, playbackUrlOf('ep1'));
      expect(audio.lastEpisodeUrl, isNot(contains('example.com')),
          reason: 'never the publisher audioUrl');
      final media = audio.lastMedia!;
      expect(media.id, 'ep1');
      expect(media.title, 'Episode ep1');
      expect(media.podcast, 'Demo');
      expect(media.duration, const Duration(seconds: 900));
    });

    test('an expired link is renewed once and playback retried', () async {
      final api = FakeApi()
        ..playbackUrlSequence['ep1'] = [
          'https://api.example/v1/media/episodes/ep1?sig=old',
          'https://api.example/v1/media/episodes/ep1?sig=new',
        ];
      final audio = FakeAudioOutput()
        ..failingUrls.add('https://api.example/v1/media/episodes/ep1?sig=old');
      final controller = _controller(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      await controller.seekSelectedEpisode(const Duration(seconds: 300));
      final calls = api.episodeCalls['ep1']!;

      await controller.playSelectedEpisode();
      expect(api.episodeCalls['ep1'], calls + 1);
      expect(audio.events.where((event) => event.startsWith('play')), [
        'play https://api.example/v1/media/episodes/ep1?sig=old@300000',
        'play https://api.example/v1/media/episodes/ep1?sig=new@300000',
      ]);
      expect(controller.playerStatus, PlayerStatus.playing);
      expect(controller.error, isNull);
      expect(controller.selectedEpisode!.episode.playbackUrl,
          'https://api.example/v1/media/episodes/ep1?sig=new');
    });

    test('a renewed link that also fails is not renewed again', () async {
      final api = FakeApi()
        ..playbackUrlSequence['ep1'] = [
          'https://media.example/ep1.mp3?sig=1',
          'https://media.example/ep1.mp3?sig=2',
          'https://media.example/ep1.mp3?sig=3',
        ];
      final audio = FakeAudioOutput()..failEpisodePlayback = true;
      final controller = _controller(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      expect(audio.playCalls, 2);
      expect(api.episodeCalls['ep1'], 2);
      expect(controller.error?.kind, ErrorKind.playback);
      expect(controller.playerStatus, PlayerStatus.paused);
    });

    test('an unchanged link is not retried', () async {
      final api = FakeApi();
      final audio = FakeAudioOutput()..failEpisodePlayback = true;
      final controller = _controller(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      expect(audio.playCalls, 1);
      expect(api.episodeCalls['ep1'], 2, reason: 'checked for a new link');
      expect(controller.error?.kind, ErrorKind.playback);
    });

    test('a stream that breaks while playing resumes with a renewed link',
        () async {
      final api = FakeApi()
        ..playbackUrlSequence['ep1'] = [
          'https://media.example/ep1.mp3?sig=1',
          'https://media.example/ep1.mp3?sig=2',
        ];
      final audio = FakeAudioOutput();
      final controller = _controller(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(minutes: 7));
      audio.emitError(Exception('403 from media server'));
      expect(controller.playerStatus, PlayerStatus.paused);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
          audio.events.last, 'play https://media.example/ep1.mp3?sig=2@420000');
      expect(controller.playerStatus, PlayerStatus.playing);
      expect(controller.error, isNull);
    });

    test('resuming keeps the loaded link after the details were refreshed',
        () async {
      final api = FakeApi()
        ..playbackUrlSequence['ep1'] = [
          'https://media.example/ep1.mp3?sig=1',
          'https://media.example/ep1.mp3?sig=2',
        ];
      final audio = FakeAudioOutput();
      final controller = _controller(api: api, audio: audio);
      await controller.loadInitialEpisodes();
      await controller.playSelectedEpisode();
      await controller.pausePlayback();
      await controller.loadInitialEpisodes();
      await Future<void>.delayed(Duration.zero);
      expect(controller.selectedEpisode!.episode.playbackUrl,
          'https://media.example/ep1.mp3?sig=2');
      await controller.playSelectedEpisode();
      expect(audio.lastEpisodeUrl, 'https://media.example/ep1.mp3?sig=1',
          reason: 'no reload just because the signature changed');
    });
  });

  group('Citations', () {
    test('Listen from seeks to playFromSec', () async {
      final audio = FakeAudioOutput();
      final controller = _controller(audio: audio);
      await controller.selectEpisode('ep1');
      await controller
          .playCitation(_citation(startSec: 120, playFromSec: 117.5));
      expect(audio.lastSeek, const Duration(milliseconds: 117500));
    });

    test('without playFromSec the passage start is used; never negative',
        () async {
      final audio = FakeAudioOutput();
      final controller = _controller(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playCitation(_citation(startSec: 95));
      expect(audio.lastSeek, const Duration(seconds: 95));
      await controller.playCitation(_citation(startSec: 1, playFromSec: -1.5));
      expect(audio.lastSeek, Duration.zero);
    });

    test('answers from the server carry playFromSec to playback', () async {
      final api = FakeApi()..citationPlayFromSec = 118.25;
      final audio = FakeAudioOutput();
      final controller = _controller(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      await controller
          .playCitation(controller.latestResponse!.citations.single);
      expect(audio.lastSeek, const Duration(milliseconds: 118250));
    });
  });

  group('Voice questions', () {
    test('send the selected episode for name hints in episode scope', () async {
      final api = FakeApi();
      final controller = _controller(api: api);
      await controller.loadInitialEpisodes();
      await controller.startRecording();
      await controller.stopRecordingAndAsk();
      expect(api.lastVoiceEpisodeId, 'ep1');

      controller.setScope(QuestionScope.library);
      await controller.startRecording();
      await controller.stopRecordingAndAsk();
      expect(api.lastVoiceEpisodeId, isNull);
    });
  });

  group('Daily transcription limit', () {
    test('usage loads with the library and after a transcription request',
        () async {
      final api = FakeApi();
      final controller = _controller(api: api);
      await controller.loadInitialEpisodes();
      await Future<void>.delayed(Duration.zero);
      expect(controller.usage!.remainingMinutes, 120);
      final calls = api.usageCalls;
      api.usage = TranscriptionUsage(
          date: '2026-10-26',
          usedMinutes: 75,
          limitMinutes: 180,
          remainingMinutes: 105);
      await controller.requestTranscription('pending');
      await Future<void>.delayed(Duration.zero);
      expect(api.usageCalls, calls + 1);
      expect(controller.usage!.remainingMinutes, 105);
    });

    test('a used-up limit has its own message, not the rate-limit text',
        () async {
      final api = FakeApi()
        ..transcribeError = ApiException(
            statusCode: 429,
            code: 'transcription_budget_exceeded',
            retryAfter: const Duration(hours: 5));
      final controller = _controller(api: api);
      await controller.selectEpisode('pending');
      await controller.requestTranscription('pending');
      expect(controller.error?.kind, ErrorKind.transcription);
      expect(controller.errorMessage,
          startsWith('Today’s transcription limit is used up'));
      expect(controller.errorMessage, isNot(contains('Too many requests')));
    });

    test('unavailable usage is not an error', () async {
      final api = FakeApi()..usageError = Exception('down');
      final controller = _controller(api: api);
      await controller.loadInitialEpisodes();
      await controller.refreshUsage();
      expect(controller.usage, isNull);
      expect(controller.error, isNull);
    });

    test('a finished transcription refreshes the usage', () {
      fakeAsync((async) {
        final api = FakeApi();
        api.statusSequence['ep5'] = [
          TranscriptionStatus.processing,
          TranscriptionStatus.ready,
        ];
        final controller = _controller(api: api);
        controller.selectEpisode('ep5');
        async.flushMicrotasks();
        final calls = api.usageCalls;
        async.elapse(const Duration(seconds: 5));
        expect(controller.isEpisodeReady, isTrue);
        expect(api.usageCalls, calls + 1);
        controller.close();
      });
    });
  });

  group('Conversations across restarts', () {
    test('an episode conversation is restored when it is selected again',
        () async {
      final store = MemoryConversationStore();
      final first = _controller(conversations: store);
      await first.selectEpisode('ep1');
      await first.submitTypedQuestion('First question');
      await first.submitTypedQuestion('Second question');
      await Future<void>.delayed(Duration.zero);
      expect(store.conversations['episode:ep1'], hasLength(2));
      await first.close();
      first.dispose();

      final api = FakeApi();
      final restarted = _controller(api: api, conversations: store);
      await restarted.selectEpisode('ep2');
      expect(restarted.conversation, isEmpty);
      await restarted.selectEpisode('ep1');
      expect(restarted.conversation.map((turn) => turn.question),
          ['First question', 'Second question']);
      await restarted.submitTypedQuestion('A follow-up');
      expect(api.lastHistory.map((turn) => turn.question),
          ['First question', 'Second question'],
          reason: 'restored turns are context for follow-ups');
    });

    test('the library conversation is restored at start', () async {
      final store = MemoryConversationStore()
        ..conversations['library'] = [_turn('Earlier library question')];
      final controller = _controller(conversations: store);
      await controller.loadInitialEpisodes();
      controller.setScope(QuestionScope.library);
      expect(
          controller.conversation.single.question, 'Earlier library question');
      await controller.submitTypedQuestion('Next');
      await Future<void>.delayed(Duration.zero);
      expect(store.conversations['library']!.map((turn) => turn.question),
          ['Earlier library question', 'Next']);
    });

    test('New conversation also clears the stored one', () async {
      final store = MemoryConversationStore();
      final controller = _controller(conversations: store);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      await Future<void>.delayed(Duration.zero);
      expect(store.conversations, contains('episode:ep1'));
      controller.startNewConversation();
      await Future<void>.delayed(Duration.zero);
      expect(store.conversations, isNot(contains('episode:ep1')));
      expect(controller.conversation, isEmpty);
    });

    test('a failing store never blocks questions', () async {
      final controller = _controller(conversations: _BrokenConversations());
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      expect(controller.conversation, hasLength(1));
      expect(controller.error, isNull);
    });
  });

  group('SharedPreferencesConversationStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('keeps the newest 30 turns of the 20 most recent conversations',
        () async {
      final store = SharedPreferencesConversationStore();
      await store.save('episode:long',
          [for (var index = 1; index <= 35; index++) _turn('Q$index')]);
      final long = await store.load('episode:long');
      expect(long, hasLength(30));
      expect(long.first.question, 'Q6');
      expect(long.last.question, 'Q35');

      for (var index = 0; index < 20; index++) {
        await store.save('episode:e$index', [_turn('About $index')]);
      }
      expect(await store.load('episode:long'), isEmpty,
          reason: 'the oldest conversation made room');
      expect((await store.load('episode:e0')).single.question, 'About 0');

      await store.save('episode:e0', [_turn('About 0'), _turn('More')]);
      await store.save('library', [_turn('Library')]);
      expect(await store.load('episode:e0'), hasLength(2),
          reason: 'saving again made it recent');
      expect(await store.load('episode:e1'), isEmpty);
    });

    test('survives a restart, clears, and keeps accounts apart', () async {
      await SharedPreferencesConversationStore(namespace: 'u1')
          .save('library', [_turn('Mine')]);
      final again = SharedPreferencesConversationStore(namespace: 'u1');
      expect((await again.load('library')).single.question, 'Mine');
      expect(
          await SharedPreferencesConversationStore(namespace: 'u2')
              .load('library'),
          isEmpty);
      await again.clear('library');
      expect(await again.load('library'), isEmpty);
      await again.save('library', [_turn('A')]);
      await again.save('library', const []);
      expect(await again.load('library'), isEmpty);
    });

    test('ignores unreadable stored data', () async {
      SharedPreferences.setMockInitialValues({
        '${SharedPreferencesConversationStore.prefix}/default/library':
            'not json',
        '${SharedPreferencesConversationStore.prefix}/default/episode:x':
            '[{"question":"Q","response":{"answerText":"A","grounded":true}},'
                '{"question":""},7]',
      });
      final store = SharedPreferencesConversationStore();
      expect(await store.load('library'), isEmpty);
      expect((await store.load('episode:x')).single.question, 'Q');
    });
  });

  group('Lock screen and headset commands', () {
    test('pause, play, skip and seek go through the app', () async {
      final audio = FakeAudioOutput();
      final controller = _controller(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(minutes: 2));

      audio.remote(const RemotePause());
      await Future<void>.delayed(Duration.zero);
      expect(controller.playerStatus, PlayerStatus.paused);

      audio.remote(const RemoteSkip(Duration(seconds: 30)));
      await Future<void>.delayed(Duration.zero);
      expect(audio.lastSeek, const Duration(minutes: 2, seconds: 30));
      expect(controller.selectedProgress.value.position,
          const Duration(minutes: 2, seconds: 30));

      audio.remote(const RemoteSkip(Duration(seconds: -15)));
      await Future<void>.delayed(Duration.zero);
      expect(audio.lastSeek, const Duration(minutes: 2, seconds: 15));

      audio.remote(const RemotePlay());
      await Future<void>.delayed(Duration.zero);
      expect(controller.playerStatus, PlayerStatus.playing);
      expect(audio.events.last,
          'play ${playbackUrlOf('ep1')}@${const Duration(minutes: 2, seconds: 15).inMilliseconds}');

      audio.remote(const RemoteSeek(Duration(minutes: 10)));
      await Future<void>.delayed(Duration.zero);
      expect(audio.lastSeek, const Duration(minutes: 10));

      audio.remote(const RemoteSkip(Duration(hours: 1)));
      await Future<void>.delayed(Duration.zero);
      expect(audio.lastSeek, const Duration(seconds: 900),
          reason: 'clamped to the episode length');

      audio.remote(const RemoteStop());
      await Future<void>.delayed(Duration.zero);
      expect(controller.playerStatus, PlayerStatus.stopped);
      expect(audio.events.last, 'stop');
    });

    test('play from the lock screen starts the selected episode', () async {
      final audio = FakeAudioOutput();
      final controller = _controller(
          audio: audio,
          positions: MemoryPlaybackPositionStore()
            ..positions['ep1'] = const Duration(seconds: 40));
      await controller.selectEpisode('ep1');
      audio.remote(const RemotePlay());
      await Future<void>.delayed(Duration.zero);
      expect(controller.isPlayingEpisode, isTrue);
      expect(audio.lastSeek, const Duration(seconds: 40));
    });

    test('a cited episode from elsewhere is skipped within itself', () async {
      final audio = FakeAudioOutput();
      final controller = _controller(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playCitation(_citation(startSec: 60, episodeId: 'ep2'));
      audio.emit(const Duration(seconds: 65));
      audio.remote(const RemoteSkip(Duration(seconds: 30)));
      await Future<void>.delayed(Duration.zero);
      expect(audio.lastSeek, const Duration(seconds: 95));
      expect(controller.nowPlaying!.id, 'ep2');
      expect(controller.selectedProgress.value.position, Duration.zero);
    });

    test('commands wait while a question is recorded or answered', () async {
      final api = FakeApi()..questionGate = Completer<void>();
      final audio = FakeAudioOutput();
      final controller = _controller(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 50));
      final answering = controller.submitTypedQuestion('What did she mean?');
      await Future<void>.delayed(Duration.zero);
      expect(controller.playerStatus, PlayerStatus.paused);
      final plays = audio.playCalls;
      audio.remote(const RemotePlay());
      audio.remote(const RemoteSkip(Duration(seconds: 30)));
      await Future<void>.delayed(Duration.zero);
      expect(audio.playCalls, plays);
      expect(audio.seekCalls, 0);
      api.questionGate!.complete();
      await answering;
      expect(controller.playerStatus, PlayerStatus.playing,
          reason: 'the question still resumes playback afterwards');
    });

    test('play during a spoken answer ends the answer, like the app button',
        () async {
      final audio = FakeAudioOutput()..blockTts = true;
      final controller = _controller(audio: audio)..setReadAnswersAloud(true);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 30));
      final answering = controller.submitTypedQuestion('Question');
      await Future<void>.delayed(Duration.zero);
      expect(controller.isSpeaking, isTrue);
      audio.remote(const RemotePlay());
      await answering;
      await Future<void>.delayed(Duration.zero);
      expect(controller.voiceState, VoiceState.idle);
      expect(controller.playerStatus, PlayerStatus.playing);
    });
  });

  group('Automatic transcription per podcast', () {
    test('the switch moves at once and is saved on the server', () async {
      final api = FakeApi()..updateSourceGate = Completer<void>();
      final sources = SourcesController(api: api);
      await sources.load();
      final saving = sources.setAutoTranscribe('src1', true);
      expect(sources.sourceById('src1')!.autoTranscribe, isTrue);
      expect(sources.isSavingSettings('src1'), isTrue);
      api.updateSourceGate!.complete();
      await saving;
      expect(
          api.sourceUpdates.single, (sourceId: 'src1', autoTranscribe: true));
      expect(sources.isSavingSettings('src1'), isFalse);
      expect(sources.sourceById('src1')!.autoTranscribe, isTrue);
      sources.close();
    });

    test('a refused change moves back and explains why', () async {
      final api = FakeApi()..updateSourceError = ApiException(statusCode: 503);
      final sources = SourcesController(api: api);
      await sources.load();
      await sources.setAutoTranscribe('src1', true);
      expect(sources.sourceById('src1')!.autoTranscribe, isFalse);
      expect(sources.settingsErrors['src1'],
          'The server had a problem. Please try again in a moment.');
      sources.close();
    });
  });
}

class _BrokenConversations implements ConversationStore {
  @override
  Future<List<ConversationTurn>> load(String key) async =>
      throw StateError('disk full');
  @override
  Future<void> save(String key, List<ConversationTurn> turns) async =>
      throw StateError('disk full');
  @override
  Future<void> clear(String key) async => throw StateError('disk full');
}
