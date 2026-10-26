import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_voice_ai/models.dart';
import 'package:podcast_voice_ai/playback_position_store.dart';
import 'package:podcast_voice_ai/podcast_api.dart';
import 'package:podcast_voice_ai/podcast_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

PodcastController makeController({
  FakeApi? api,
  FakeRecorder? recorder,
  FakeAudioOutput? audio,
  PlaybackPositionStore? positions,
}) =>
    PodcastController(
      api: api ?? FakeApi(),
      recorder: recorder ?? FakeRecorder(),
      audioOutput: audio ?? FakeAudioOutput(),
      positionStore: positions,
    );

Citation citationAt(double startSec, {String episodeId = 'ep1'}) => Citation(
      segmentId: 'seg-$startSec',
      episodeId: episodeId,
      episodeTitle: 'Episode $episodeId',
      startSec: startSec,
      endSec: startSec + 10,
      text: 'citation text',
      score: 0.8,
    );

void main() {
  group('PodcastController', () {
    test('library list renders paginated episodes via controller pagination',
        () async {
      final api = FakeApi();
      final controller = makeController(api: api);

      await controller.loadInitialEpisodes();
      expect(controller.episodes.length, 1);
      expect(controller.hasMoreEpisodes, true);

      await controller.loadMoreEpisodes();
      expect(controller.episodes.length, 2);
      expect(controller.hasMoreEpisodes, false);
      expect(api.listCalls, 2);
    });

    test(
        'voice capture state machine transitions idle -> recording -> processing -> speaking -> idle',
        () async {
      final controller = makeController();
      await controller.selectEpisode('ep1');
      final seenStates = <VoiceState>[];
      controller.addListener(() => seenStates.add(controller.voiceState));

      await controller.startRecording();
      await controller.stopRecordingAndAsk();

      expect(controller.voiceState, VoiceState.idle);
      expect(seenStates, contains(VoiceState.recording));
      expect(seenStates, contains(VoiceState.processing));
      expect(seenStates, contains(VoiceState.speaking));
    });

    test('citation tap seeks player to expected timestamp', () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playCitation(citationAt(95));
      expect(audio.lastEpisodeUrl, 'https://example.com/ep1.mp3');
      expect(audio.lastSeek, const Duration(seconds: 95));
    });

    test('handles pending transcript, network failure, and refusal response',
        () async {
      final api = FakeApi();
      final controller = makeController(api: api);

      await controller.selectEpisode('pending');
      expect(controller.isEpisodeReady, false);

      await controller.startRecording();
      expect(controller.voiceState, VoiceState.idle);

      api.throwOnList = true;
      await controller.loadInitialEpisodes();
      expect(controller.error?.kind, ErrorKind.library);
      expect(controller.errorMessage, isNot(contains('network failure')));

      api.throwOnList = false;
      api.refuseAnswer = true;
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('unsupported question');

      expect(controller.latestResponse, isNotNull);
      expect(controller.latestResponse!.grounded, false);
      expect(controller.latestResponse!.refusalReason,
          'insufficient_retrieval_confidence');
    });

    test(
        'releasing before microphone permission completes discards the empty recording',
        () async {
      final api = FakeApi();
      final permission = Completer<void>();
      final recorder = FakeRecorder()..startGate = permission;
      final controller = makeController(api: api, recorder: recorder);
      await controller.selectEpisode('ep1');
      final starting = controller.startRecording();
      expect(controller.voiceState, VoiceState.starting);
      final stopping = controller.stopRecordingAndAsk();
      expect(controller.voiceState, VoiceState.processing);
      expect(recorder.stopCalls, 0);
      permission.complete();
      await Future.wait([starting, stopping]);
      expect(recorder.stopCalls, 1);
      expect(recorder.started, false);
      expect(api.transcriptionCalls, 0);
      expect(api.questionCalls, 0);
      expect(controller.errorMessage, isNull);
      expect(controller.voiceState, VoiceState.idle);
    });

    test('changing episode clears its conversation', () async {
      final controller = makeController();
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('What was discussed?');
      expect(controller.latestResponse, isNotNull);
      expect(controller.lastQuestionText, 'What was discussed?');
      await controller.selectEpisode('ep2');
      expect(controller.conversation, isEmpty);
      expect(controller.latestResponse, isNull);
      expect(controller.lastQuestionText, isNull);
      expect(controller.selectedEpisode!.episode.id, 'ep2');
    });

    test('a voice follow-up keeps earlier turns while it is answered',
        () async {
      final api = FakeApi()..transcriptionGate = Completer<void>();
      final recorder = FakeRecorder();
      final controller = makeController(api: api, recorder: recorder);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      await controller.submitTypedQuestion('Previous question');
      final previous = controller.conversation.single;

      await controller.startRecording();
      await controller.cancelRecording();
      recorder.startGate = Completer<void>();
      final starting = controller.startRecording();
      final earlyRelease = controller.stopRecordingAndAsk();
      recorder.startGate!.complete();
      await Future.wait([starting, earlyRelease]);
      expect(controller.conversation, [previous]);
      expect(api.transcriptionCalls, 0);

      await controller.startRecording();
      final submitting = controller.stopRecordingAndAsk();
      expect(controller.voiceState, VoiceState.processing);
      expect(controller.isTranscribingVoice, true);
      expect(controller.pendingQuestion, isNull);
      expect(controller.conversation, [previous]);
      await Future<void>.delayed(Duration.zero);
      expect(api.transcriptionCalls, 1);

      api.transcriptionGate!.complete();
      await submitting;
      expect(controller.conversation, hasLength(2));
      expect(controller.conversation.first, same(previous));
      expect(controller.lastQuestionText, 'What was discussed?');
      expect(controller.isTranscribingVoice, false);
      expect(controller.voiceState, VoiceState.idle);
    });

    test('submitted question is visible while the answer is pending', () async {
      final api = FakeApi()..questionGate = Completer<void>();
      final controller = makeController(api: api);
      await controller.selectEpisode('ep1');
      final answer = controller.submitTypedQuestion('  What was discussed?  ');
      expect(controller.lastQuestionText, 'What was discussed?');
      expect(controller.pendingQuestion, 'What was discussed?');
      expect(controller.latestResponse, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(api.lastQuestionText, controller.lastQuestionText);
      expect(api.lastTopK, 10);
      api.questionGate!.complete();
      await answer;
      expect(controller.pendingQuestion, isNull);
    });

    test('voice questions retain their recognized text even if answering fails',
        () async {
      final api = FakeApi()..failQuestion = true;
      final controller = makeController(api: api);
      await controller.selectEpisode('ep1');
      await controller.startRecording();
      await controller.stopRecordingAndAsk();
      expect(controller.lastQuestionText, 'What was discussed?');
      expect(api.lastQuestionText, controller.lastQuestionText);
      expect(controller.latestResponse, isNull);
      expect(controller.error?.kind, ErrorKind.question);
      expect(controller.errorMessage, isNot(contains('question unavailable')));
    });

    test('citation resolves its own episode and preserves fractional timestamp',
        () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep2');
      await controller.playCitation(citationAt(12.45));
      expect(audio.lastEpisodeUrl, 'https://example.com/ep1.mp3');
      expect(audio.lastSeek, const Duration(milliseconds: 12450));
      expect(controller.selectedEpisode!.episode.id, 'ep2');
      expect(controller.nowPlaying?.id, 'ep1');
      expect(controller.isPlayingEpisode, false);
      expect(controller.isPlayingCitation, true);
    });

    test(
        'overlapping questions and episode changes cannot reassign a pending answer',
        () async {
      final api = FakeApi()..questionGate = Completer<void>();
      final controller = makeController(api: api);
      await controller.selectEpisode('ep1');
      final first = controller.submitTypedQuestion('First question');
      await Future<void>.delayed(Duration.zero);
      await controller.submitTypedQuestion('Second question');
      await controller.selectEpisode('ep2');
      expect(api.questionCalls, 1);
      expect(api.lastQuestionEpisode, 'ep1');
      expect(controller.selectedEpisode!.episode.id, 'ep1');
      api.questionGate!.complete();
      await first;
    });

    test('typed questions also wait for a ready transcript', () async {
      final api = FakeApi();
      final controller = makeController(api: api);
      await controller.selectEpisode('pending');
      await controller.submitTypedQuestion('Question');
      expect(api.questionCalls, 0);
      expect(controller.canAskQuestion, false);
    });

    test('text only mode skips synthesis and still returns citations',
        () async {
      final api = FakeApi();
      final audio = FakeAudioOutput();
      final controller = makeController(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      await controller.submitTypedQuestion('Question');
      expect(controller.latestResponse!.citations, isNotEmpty);
      expect(api.synthesisCalls, 0);
      expect(audio.ttsCalls, 0);
      expect(controller.voiceState, VoiceState.idle);
    });

    test('speech playback receives the server MIME type', () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      expect(audio.lastMimeType, 'audio/wav');
    });

    test('speech failure preserves the text answer', () async {
      final api = FakeApi()..failSynthesis = true;
      final controller = makeController(api: api);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      expect(controller.latestResponse!.grounded, true);
      expect(controller.error?.kind, ErrorKind.speech);
      expect(controller.errorMessage, contains('ready to read'));
      expect(controller.voiceState, VoiceState.idle);
    });

    test('stop audio unlocks questions while speech is playing', () async {
      final audio = FakeAudioOutput()..blockTts = true;
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      final answer = controller.submitTypedQuestion('Question');
      await Future<void>.delayed(Duration.zero);
      expect(controller.voiceState, VoiceState.speaking);
      expect(controller.isSpeaking, true);
      await controller.stopAudio();
      await answer;
      expect(controller.canAskQuestion, true);
      expect(controller.latestResponse, isNotNull);
    });

    test('citation playback errors appear in the app instead of escaping',
        () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      audio.failEpisodePlayback = true;
      await controller.playCitation(controller.latestResponse!.citations.first);
      expect(controller.error?.kind, ErrorKind.playback);
      expect(controller.errorMessage, contains('couldn’t play'));
      expect(controller.isPlayingCitation, false);
    });

    test('empty refresh clears a previously selected episode', () async {
      final api = FakeApi();
      final controller = makeController(api: api);
      await controller.loadInitialEpisodes();
      api.emptyLibrary = true;
      await controller.loadInitialEpisodes();
      expect(controller.episodes, isEmpty);
      expect(controller.selectedEpisode, isNull);
      expect(controller.canAskQuestion, false);
    });

    test('refreshing keeps the selected episode and its conversation',
        () async {
      final api = FakeApi();
      final controller = makeController(api: api);
      await controller.loadInitialEpisodes();
      await controller.selectEpisode('ep2');
      controller.setReadAnswersAloud(false);
      await controller.submitTypedQuestion('Question');
      await controller.loadInitialEpisodes();
      expect(controller.selectedEpisode!.episode.id, 'ep2');
      expect(controller.conversation, hasLength(1));
    });

    test('late episode detail response cannot overwrite a newer selection',
        () async {
      final api = FakeApi();
      final olderResponse = Completer<void>();
      api.episodeGates['ep1'] = olderResponse;
      final controller = makeController(api: api);
      final firstSelection = controller.selectEpisode('ep1');
      await Future<void>.delayed(Duration.zero);
      await controller.selectEpisode('ep2');
      olderResponse.complete();
      await firstSelection;
      expect(controller.selectedEpisode!.episode.id, 'ep2');
      expect(controller.isSelectingEpisode, false);
    });

    test('closing during a request prevents notifying a disposed controller',
        () async {
      final api = FakeApi()..questionGate = Completer<void>();
      final controller = makeController(api: api);
      await controller.selectEpisode('ep1');
      final answer = controller.submitTypedQuestion('Question');
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      controller.dispose();
      api.questionGate!.complete();
      await answer;
      expect(controller.latestResponse, isNull);
    });

    test('cancelling during microphone startup stops without sending audio',
        () async {
      final api = FakeApi();
      final startup = Completer<void>();
      final recorder = FakeRecorder()..startGate = startup;
      final controller = makeController(api: api, recorder: recorder);
      await controller.selectEpisode('ep1');
      final starting = controller.startRecording();
      final cancelling = controller.cancelRecording();
      expect(controller.voiceState, VoiceState.processing);
      expect(recorder.stopCalls, 0);
      startup.complete();
      await Future.wait([starting, cancelling]);
      expect(recorder.stopCalls, 1);
      expect(recorder.started, false);
      expect(api.transcriptionCalls, 0);
      expect(api.questionCalls, 0);
      expect(controller.voiceState, VoiceState.idle);
    });

    test('permission failure during early release stays idle without uploading',
        () async {
      final api = FakeApi();
      final startup = Completer<void>();
      final recorder = FakeRecorder()..startGate = startup;
      final controller = makeController(api: api, recorder: recorder);
      await controller.selectEpisode('ep1');
      final starting = controller.startRecording();
      final stopping = controller.stopRecordingAndAsk();
      await Future<void>.delayed(Duration.zero);
      startup.completeError(Exception('Microphone permission denied'));
      await Future.wait([starting, stopping]);
      expect(recorder.stopCalls, 0);
      expect(api.transcriptionCalls, 0);
      expect(controller.errorMessage, contains('Microphone access is off'));
      expect(controller.voiceState, VoiceState.idle);
    });
  });

  group('Playback', () {
    test('episode playback starts at zero and can be paused', () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      expect(audio.lastEpisodeUrl, 'https://example.com/ep1.mp3');
      expect(audio.lastSeek, Duration.zero);
      expect(controller.isPlayingEpisode, true);
      expect(controller.playerStatus, PlayerStatus.playing);

      await controller.pausePlayback();
      expect(audio.pauseCalls, 1);
      expect(controller.isPlayingEpisode, false);
      expect(controller.playerStatus, PlayerStatus.paused);
      expect(audio.stopCalls, 1, reason: 'only the stop when selecting');
    });

    test('pause and resume continue from the paused position', () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.togglePlayback();
      audio.emit(const Duration(seconds: 30),
          duration: const Duration(minutes: 20));
      expect(controller.selectedProgress.value.position,
          const Duration(seconds: 30));
      expect(controller.selectedProgress.value.duration,
          const Duration(minutes: 20));

      audio.position = const Duration(seconds: 31);
      await controller.togglePlayback();
      expect(controller.playerStatus, PlayerStatus.paused);
      expect(controller.selectedProgress.value.position,
          const Duration(seconds: 31));

      await controller.togglePlayback();
      expect(audio.playCalls, 2);
      expect(audio.lastSeek, const Duration(seconds: 31));
      expect(controller.isPlayingEpisode, true);
    });

    test('seeking moves the player, or the start point when not loaded',
        () async {
      final audio = FakeAudioOutput();
      final positions = MemoryPlaybackPositionStore();
      final controller = makeController(audio: audio, positions: positions);
      await controller.selectEpisode('ep1');

      await controller.seekSelectedEpisode(const Duration(seconds: 200));
      expect(audio.seekCalls, 0);
      expect(controller.selectedProgress.value.position,
          const Duration(seconds: 200));
      expect(positions.positions['ep1'], const Duration(seconds: 200));
      await controller.playSelectedEpisode();
      expect(audio.lastSeek, const Duration(seconds: 200));

      await controller.seekSelectedEpisode(const Duration(seconds: 120));
      expect(audio.seekCalls, 1);
      expect(audio.lastSeek, const Duration(seconds: 120));
      expect(controller.playerStatus, PlayerStatus.playing);

      await controller.pausePlayback();
      await controller.seekSelectedEpisode(const Duration(hours: 2));
      expect(audio.lastSeek, const Duration(seconds: 900),
          reason: 'clamped to the episode length');
      expect(controller.playerStatus, PlayerStatus.paused);
    });

    test('a pause during episode startup prevents late playback', () async {
      final audio = FakeAudioOutput()..startGate = Completer<void>();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      final playing = controller.playSelectedEpisode();
      await Future<void>.delayed(Duration.zero);
      expect(controller.playerStatus, PlayerStatus.loading);
      await controller.pausePlayback();
      audio.startGate!.complete();
      await playing;
      expect(controller.playerStatus, PlayerStatus.paused);
      expect(controller.isPlayingEpisode, false);
    });

    test('changing episode stops its playback', () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      await controller.selectEpisode('ep2');
      expect(controller.selectedEpisode!.episode.id, 'ep2');
      expect(controller.isPlayingEpisode, false);
      expect(controller.nowPlaying, isNull);
      expect(audio.events.last, 'stop');
    });

    test('citation highlight follows playback and clears on pause', () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      await controller.submitTypedQuestion('Question');
      final citation = controller.latestResponse!.citations.first;
      await controller.playCitation(citation);
      expect(controller.activeCitationId, citation.segmentId);
      expect(controller.isPlayingCitation, true);
      expect(audio.lastSeek, const Duration(seconds: 120));
      await controller.pausePlayback();
      expect(controller.activeCitationId, isNull);
      expect(controller.isPlayingCitation, false);
    });

    test('episode playback failure is dismissible without losing selection',
        () async {
      final audio = FakeAudioOutput()..failEpisodePlayback = true;
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      expect(controller.error?.kind, ErrorKind.playback);
      expect(controller.isPlayingEpisode, false);
      controller.dismissError();
      expect(controller.errorMessage, isNull);
      expect(controller.selectedEpisode!.episode.id, 'ep1');
    });

    test('player pauses and errors that the app did not request are followed',
        () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(Duration.zero, playing: false);
      expect(controller.playerStatus, PlayerStatus.playing,
          reason: 'updates from before playback started are ignored');
      audio.emit(const Duration(seconds: 5));
      audio.emit(const Duration(seconds: 6), playing: false);
      expect(controller.playerStatus, PlayerStatus.paused);

      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 7));
      audio.emitError(Exception('stream dropped'));
      expect(controller.playerStatus, PlayerStatus.paused);
      expect(controller.error?.kind, ErrorKind.playback);
    });

    test('completion resets the position so the next play starts over',
        () async {
      final audio = FakeAudioOutput();
      final positions = MemoryPlaybackPositionStore();
      final controller = makeController(audio: audio, positions: positions);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 450));
      await controller.pausePlayback();
      expect(positions.positions['ep1'], const Duration(seconds: 450));
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 900), completed: true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.playerStatus, PlayerStatus.stopped);
      expect(controller.selectedProgress.value.position, Duration.zero);
      expect(positions.positions.containsKey('ep1'), false);
      await controller.playSelectedEpisode();
      expect(audio.lastSeek, Duration.zero);
    });

    test('positions are saved while playing, not only on pause', () async {
      final audio = FakeAudioOutput();
      final positions = MemoryPlaybackPositionStore();
      final controller = makeController(audio: audio, positions: positions);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);
      expect(positions.positions['ep1'], isNull);
      audio.emit(const Duration(seconds: 12));
      await Future<void>.delayed(Duration.zero);
      expect(positions.positions['ep1'], const Duration(seconds: 12));
    });

    test('the playback position survives an app restart', () async {
      SharedPreferences.setMockInitialValues({});
      final audio = FakeAudioOutput();
      final first = makeController(
          audio: audio, positions: SharedPreferencesPositionStore());
      await first.selectEpisode('ep1');
      await first.playSelectedEpisode();
      audio.emit(const Duration(minutes: 4, seconds: 5));
      await first.close();
      first.dispose();

      final restartedAudio = FakeAudioOutput();
      final restarted = makeController(
          audio: restartedAudio, positions: SharedPreferencesPositionStore());
      await restarted.selectEpisode('ep1');
      expect(restarted.selectedProgress.value.position,
          const Duration(minutes: 4, seconds: 5));
      expect(restarted.selectedProgress.value.duration,
          const Duration(seconds: 900));
      await restarted.playSelectedEpisode();
      expect(restartedAudio.lastSeek, const Duration(minutes: 4, seconds: 5));

      await restarted.selectEpisode('ep2');
      expect(restarted.selectedProgress.value.position, Duration.zero);
    });

    test('a saved position at the very end starts the episode over', () async {
      final positions = MemoryPlaybackPositionStore()
        ..positions['ep1'] = const Duration(seconds: 898);
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio, positions: positions);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      expect(audio.lastSeek, Duration.zero);
    });

    test('a citation from another episode keeps the selected episode position',
        () async {
      final audio = FakeAudioOutput();
      final positions = MemoryPlaybackPositionStore();
      final controller = makeController(audio: audio, positions: positions);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 42));
      await controller.playCitation(citationAt(60, episodeId: 'ep2'));
      await Future<void>.delayed(Duration.zero);
      expect(positions.positions['ep1'], const Duration(seconds: 42));
      expect(controller.nowPlaying?.id, 'ep2');
      expect(controller.selectedProgress.value.position,
          const Duration(seconds: 42));
      audio.emit(const Duration(seconds: 75));
      await controller.toggleNowPlaying();
      expect(controller.playerStatus, PlayerStatus.paused);
      await controller.toggleNowPlaying();
      expect(audio.lastEpisodeUrl, 'https://example.com/ep2.mp3');
      expect(audio.lastSeek, const Duration(seconds: 75));
    });
  });

  group('Questions about what was just heard', () {
    test(
        'a typed question while playing sends the position, pauses, then resumes after the spoken answer',
        () async {
      final api = FakeApi();
      final audio = FakeAudioOutput()..blockTts = true;
      final controller = makeController(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(minutes: 12, seconds: 34));
      expect(controller.questionPosition,
          const Duration(minutes: 12, seconds: 34));
      audio.position = const Duration(minutes: 12, seconds: 34, milliseconds: 500);

      final answer = controller.submitTypedQuestion('What did they mean?');
      await Future<void>.delayed(Duration.zero);
      expect(controller.voiceState, VoiceState.speaking);
      expect(controller.playerStatus, PlayerStatus.paused);
      expect(api.lastQuestionEpisode, 'ep1');
      expect(api.lastPositionSec, 754.5);
      expect(controller.conversation.single.positionSec, 754.5);
      expect(audio.events, containsAllInOrder(['pause', 'tts']));
      expect(audio.stopCalls, 1, reason: 'paused, not stopped');

      audio.ttsGate!.complete();
      await answer;
      expect(controller.playerStatus, PlayerStatus.playing);
      expect(audio.events.last, 'play https://example.com/ep1.mp3@754500');
      expect(controller.questionPosition, isNotNull);
    });

    test('a voice question captures the position when recording starts',
        () async {
      final api = FakeApi();
      final audio = FakeAudioOutput();
      final recorder = FakeRecorder();
      final controller =
          makeController(api: api, audio: audio, recorder: recorder);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 100));

      await controller.startRecording();
      expect(recorder.started, true);
      expect(audio.pauseCalls, 1);
      expect(controller.playerStatus, PlayerStatus.paused);
      expect(controller.questionPosition, const Duration(seconds: 100));

      await controller.stopRecordingAndAsk();
      expect(api.lastPositionSec, 100);
      expect(controller.playerStatus, PlayerStatus.playing);
      expect(audio.lastSeek, const Duration(seconds: 100));
    });

    test('cancelling a recording resumes the episode', () async {
      final audio = FakeAudioOutput();
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 20));
      await controller.startRecording();
      expect(controller.playerStatus, PlayerStatus.paused);
      await controller.cancelRecording();
      expect(controller.playerStatus, PlayerStatus.playing);
      expect(audio.lastSeek, const Duration(seconds: 20));
    });

    test('a paused episode sends its position but stays paused', () async {
      final api = FakeApi();
      final audio = FakeAudioOutput();
      final controller = makeController(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 50));
      await controller.pausePlayback();

      await controller.submitTypedQuestion('Who is speaking?');
      expect(api.lastPositionSec, 50);
      expect(controller.playerStatus, PlayerStatus.paused);
      expect(audio.playCalls, 1);
    });

    test('a restored position counts as paused there', () async {
      final api = FakeApi();
      final positions = MemoryPlaybackPositionStore()
        ..positions['ep1'] = const Duration(seconds: 61);
      final controller = makeController(api: api, positions: positions);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      expect(controller.questionPosition, const Duration(seconds: 61));
      await controller.submitTypedQuestion('Question');
      expect(api.lastPositionSec, 61);
    });

    test('dismissing the position asks without it until playback moves',
        () async {
      final api = FakeApi();
      final audio = FakeAudioOutput();
      final controller = makeController(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 50));
      controller.dismissQuestionPosition();
      expect(controller.questionPosition, isNull);

      await controller.submitTypedQuestion('Question');
      expect(api.lastPositionSec, isNull);
      expect(api.lastQuestionEpisode, 'ep1');
      expect(controller.playerStatus, PlayerStatus.playing,
          reason: 'resuming playback counts as moving on');
      expect(controller.questionPosition, isNotNull);
    });

    test('without playback no position is sent', () async {
      final api = FakeApi();
      final controller = makeController(api: api);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      expect(api.lastPositionSec, isNull);
    });

    test('a failed answer leaves the episode paused', () async {
      final api = FakeApi()..failQuestion = true;
      final audio = FakeAudioOutput();
      final controller = makeController(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 50));
      await controller.submitTypedQuestion('Question');
      expect(controller.error?.kind, ErrorKind.question);
      expect(controller.playerStatus, PlayerStatus.paused);
      expect(audio.playCalls, 1);
    });

    test('a player that cannot pause does not block the question', () async {
      final api = FakeApi();
      final audio = FakeAudioOutput()..failPause = true;
      final controller = makeController(api: api, audio: audio);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 40));
      await controller.submitTypedQuestion('Question');
      expect(api.lastPositionSec, 40);
      expect(controller.voiceState, VoiceState.idle);
      expect(controller.latestResponse, isNotNull);
    });

    test('skipping the spoken answer resumes the episode', () async {
      final audio = FakeAudioOutput()..blockTts = true;
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 30));
      final answer = controller.submitTypedQuestion('Question');
      await Future<void>.delayed(Duration.zero);
      expect(controller.isSpeaking, true);
      await controller.stopSpeech();
      await answer;
      expect(audio.stopSpeechCalls, 1);
      expect(controller.voiceState, VoiceState.idle);
      expect(controller.playerStatus, PlayerStatus.playing);
    });

    test('playing a citation during the spoken answer replaces the resume',
        () async {
      final audio = FakeAudioOutput()..blockTts = true;
      final controller = makeController(audio: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 30));
      final answer = controller.submitTypedQuestion('Question');
      await Future<void>.delayed(Duration.zero);
      await controller.playCitation(controller.latestResponse!.citations.first);
      await answer;
      expect(audio.lastSeek, const Duration(seconds: 120));
      expect(controller.playerStatus, PlayerStatus.playing);
      expect(controller.voiceState, VoiceState.idle);
      expect(audio.playCalls, 2);
    });
  });

  group('Conversation', () {
    test('follow-ups send the last six grounded turns, oldest first',
        () async {
      final api = FakeApi();
      final controller = makeController(api: api);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      for (var index = 1; index <= 8; index++) {
        api.refuseAnswer = index == 7;
        await controller.submitTypedQuestion('Question $index');
      }
      api.refuseAnswer = false;
      expect(controller.conversation, hasLength(8));
      await controller.submitTypedQuestion('Question 9');
      expect(api.lastHistory.map((turn) => turn.question), [
        'Question 2',
        'Question 3',
        'Question 4',
        'Question 5',
        'Question 6',
        'Question 8',
      ]);
      expect(api.lastHistory.first.answer,
          'The host discussed architecture and citations.');
      expect(controller.conversation.last.question, 'Question 9');
    });

    test('a new conversation clears the history', () async {
      final api = FakeApi();
      final controller = makeController(api: api);
      await controller.selectEpisode('ep1');
      controller.setReadAnswersAloud(false);
      await controller.submitTypedQuestion('First');
      await controller.submitTypedQuestion('Second');
      expect(api.lastHistory.single.question, 'First');
      controller.startNewConversation();
      expect(controller.conversation, isEmpty);
      await controller.submitTypedQuestion('Fresh start');
      expect(api.lastHistory, isEmpty);
    });

    test('each scope keeps its own conversation', () async {
      final api = FakeApi();
      final controller = makeController(api: api);
      await controller.loadInitialEpisodes();
      controller.setReadAnswersAloud(false);
      await controller.submitTypedQuestion('Episode question');
      controller.setScope(QuestionScope.library);
      expect(controller.conversation, isEmpty);
      await controller.submitTypedQuestion('Library question');
      expect(api.lastHistory, isEmpty);

      await controller.selectEpisode('ep2');
      expect(controller.conversation.single.question, 'Library question');
      controller.setScope(QuestionScope.episode);
      expect(controller.conversation, isEmpty,
          reason: 'switching episode cleared the episode conversation');
    });

    test(
        'library scope omits the episode and position and accepts an unready selection',
        () async {
      final api = FakeApi()..citationEpisodeId = 'ep2';
      final audio = FakeAudioOutput();
      final controller = makeController(api: api, audio: audio);
      await controller.loadInitialEpisodes();
      await controller.selectEpisode('pending');
      controller.setReadAnswersAloud(false);
      await controller.playSelectedEpisode();
      audio.emit(const Duration(seconds: 80));
      expect(controller.canAskQuestion, false);

      controller.setScope(QuestionScope.library);
      expect(controller.canAskQuestion, true);
      expect(controller.questionPosition, isNull);
      await controller.submitTypedQuestion('What do all episodes share?');
      expect(api.questionCalls, 1);
      expect(api.askedWithEpisode, false);
      expect(api.lastPositionSec, isNull);
      expect(controller.playerStatus, PlayerStatus.playing,
          reason: 'playback still pauses and resumes around the question');

      await controller.playCitation(controller.latestResponse!.citations.single);
      expect(audio.lastEpisodeUrl, 'https://example.com/ep2.mp3');
      expect(controller.selectedEpisode!.episode.id, 'pending');
    });

    test('library scope is unavailable when nothing is ready', () async {
      final api = FakeApi()
        ..library = [
          demoEpisode('a', status: TranscriptionStatus.pending),
          demoEpisode('b', status: TranscriptionStatus.failed),
        ]
        ..sources = [demoSource('src1', 'Demo', ready: 0)];
      final controller = makeController(api: api);
      await controller.loadInitialEpisodes();
      await Future<void>.delayed(Duration.zero);
      controller.setScope(QuestionScope.library);
      expect(controller.hasReadyEpisodes, false);
      expect(controller.canAskQuestion, false);
      expect(controller.canUsePushToTalk, false);
    });
  });

  group('Transcription requests', () {
    test('a requested transcription is polled every 5 s until ready', () {
      fakeAsync((async) {
        final api = FakeApi()
          ..library = [
            demoEpisode('ep1'),
            demoEpisode('ep9', status: TranscriptionStatus.pending),
          ]
          ..pageSize = 5;
        final controller = makeController(api: api);
        controller.loadInitialEpisodes();
        async.flushMicrotasks();
        controller.selectEpisode('ep9');
        async.flushMicrotasks();
        expect(controller.isEpisodeReady, false);

        api.statusSequence['ep9'] = [
          TranscriptionStatus.processing,
          TranscriptionStatus.ready,
        ];
        controller.requestTranscription('ep9');
        expect(controller.isTranscriptionRequested('ep9'), true);
        async.flushMicrotasks();
        expect(api.transcribeCalls, 1);
        expect(controller.selectedEpisode!.transcriptionStatus,
            TranscriptionStatus.queued);
        expect(
            controller.episodes
                .firstWhere((episode) => episode.id == 'ep9')
                .transcriptionStatus,
            TranscriptionStatus.queued);
        final callsBefore = api.episodeCalls['ep9']!;

        async.elapse(const Duration(seconds: 4));
        expect(api.episodeCalls['ep9'], callsBefore);
        async.elapse(const Duration(seconds: 1));
        expect(api.episodeCalls['ep9'], callsBefore + 1);
        expect(controller.selectedEpisode!.transcriptionStatus,
            TranscriptionStatus.processing);

        async.elapse(const Duration(seconds: 5));
        expect(controller.isEpisodeReady, true);
        expect(
            controller.episodes
                .firstWhere((episode) => episode.id == 'ep9')
                .transcriptionStatus,
            TranscriptionStatus.ready);

        async.elapse(const Duration(seconds: 30));
        expect(api.episodeCalls['ep9'], callsBefore + 2);
        controller.close();
      });
    });

    test('polling stops when the controller is closed', () {
      fakeAsync((async) {
        final api = FakeApi();
        final controller = makeController(api: api);
        controller.selectEpisode('pending');
        async.flushMicrotasks();
        api.statusSequence['pending'] = [TranscriptionStatus.processing];
        controller.requestTranscription('pending');
        async.elapse(const Duration(seconds: 5));
        final calls = api.episodeCalls['pending']!;
        controller.close();
        controller.dispose();
        async.elapse(const Duration(minutes: 1));
        expect(api.episodeCalls['pending'], calls);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a selected episode that is already processing is followed', () {
      fakeAsync((async) {
        final api = FakeApi();
        api.statusSequence['ep5'] = [
          TranscriptionStatus.processing,
          TranscriptionStatus.failed,
        ];
        final controller = makeController(api: api);
        controller.selectEpisode('ep5');
        async.flushMicrotasks();
        expect(controller.selectedEpisode!.transcriptionStatus,
            TranscriptionStatus.processing);
        async.elapse(const Duration(seconds: 5));
        expect(controller.selectedEpisode!.transcriptionStatus,
            TranscriptionStatus.failed);
        expect(async.pendingTimers, isEmpty);
        controller.close();
      });
    });

    test('a rate-limited request shows when to try again', () async {
      final api = FakeApi()
        ..transcribeError = ApiException(
            statusCode: 429, retryAfter: const Duration(seconds: 30));
      final controller = makeController(api: api);
      await controller.selectEpisode('pending');
      await controller.requestTranscription('pending');
      expect(controller.error?.kind, ErrorKind.transcription);
      expect(
          controller.errorMessage, 'Too many requests, try again in 30 s.');
      expect(controller.isTranscriptionRequested('pending'), false);
      await controller.close();
    });
  });

  group('Library filters', () {
    test('search, podcast and readiness filters are sent to the server', () {
      fakeAsync((async) {
        final api = FakeApi()..pageSize = 10;
        final controller = makeController(api: api);
        controller.loadInitialEpisodes();
        async.flushMicrotasks();
        final calls = api.listCalls;

        controller.setLibraryQuery('E');
        controller.setLibraryQuery('Ep');
        controller.setLibraryQuery('Episode 2 ');
        async.elapse(const Duration(milliseconds: 300));
        expect(api.listCalls, calls);
        async.elapse(const Duration(milliseconds: 200));
        expect(api.listCalls, calls + 1);
        expect(api.lastListQuery, 'Episode 2');
        expect(controller.episodes.map((episode) => episode.id), ['ep2']);
        expect(controller.selectedEpisode!.episode.id, 'ep1',
            reason: 'filtering the list keeps the selection');

        controller.setSourceFilter('src1');
        async.flushMicrotasks();
        expect(api.lastListSourceId, 'src1');
        controller.setOnlyReady(true);
        async.flushMicrotasks();
        expect(api.lastListStatuses, {TranscriptionStatus.ready});
        expect(api.lastListQuery, 'Episode 2');
        expect(controller.hasLibraryFilter, true);
        controller.close();
      });
    });
  });

  group('SharedPreferencesPositionStore', () {
    test('saves, clears and keeps only the most recent episodes', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPreferencesPositionStore(maxEntries: 2);
      await store.save('a', const Duration(seconds: 1));
      await store.save('b', const Duration(seconds: 2));
      await store.save('a', const Duration(seconds: 3));
      await store.save('c', const Duration(seconds: 4));
      expect(await store.load('a'), const Duration(seconds: 3));
      expect(await store.load('b'), isNull);
      expect(await store.load('c'), const Duration(seconds: 4));
      await store.clear('a');
      expect(await store.load('a'), isNull);
    });

    test('ignores unreadable stored data', () async {
      SharedPreferences.setMockInitialValues(
          {SharedPreferencesPositionStore.storageKey: 'not json'});
      final store = SharedPreferencesPositionStore();
      expect(await store.load('a'), isNull);
      await store.save('a', const Duration(seconds: 9));
      expect(await store.load('a'), const Duration(seconds: 9));
    });
  });
}
