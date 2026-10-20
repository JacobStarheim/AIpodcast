import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_voice_ai/audio_output.dart';
import 'package:podcast_voice_ai/models.dart';
import 'package:podcast_voice_ai/podcast_api.dart';
import 'package:podcast_voice_ai/podcast_controller.dart';
import 'package:podcast_voice_ai/voice_recorder.dart';

class FakeApi implements PodcastApi {
  int listCalls = 0;
  bool throwOnList = false;
  bool refuseAnswer = false;
  bool emptyLibrary = false;
  bool failSynthesis = false;
  bool failQuestion = false;
  int questionCalls = 0;
  int transcriptionCalls = 0;
  int synthesisCalls = 0;
  String? lastQuestionEpisode;
  String? lastQuestionText;
  Completer<void>? questionGate;
  Completer<void>? transcriptionGate;
  final Map<String, Completer<void>> episodeGates = {};

  @override
  Future<EpisodePage> listEpisodes({String? cursor, int limit = 20}) async {
    if (throwOnList) {
      throw Exception('network failure');
    }

    listCalls += 1;
    if (emptyLibrary) return EpisodePage(items: [], nextCursor: null);
    if (cursor == null) {
      return EpisodePage(
        items: [
          EpisodeSummary(
            id: 'ep1',
            sourceId: 'src1',
            sourceName: 'Demo',
            title: 'Episode 1',
            description: 'First',
            publishedAt: DateTime.parse('2025-01-01T00:00:00Z'),
            audioUrl: 'https://example.com/e1.mp3',
            transcriptionStatus: TranscriptionStatus.ready,
          ),
        ],
        nextCursor: 'cursor-2',
      );
    }

    return EpisodePage(
      items: [
        EpisodeSummary(
          id: 'ep2',
          sourceId: 'src1',
          sourceName: 'Demo',
          title: 'Episode 2',
          description: 'Second',
          publishedAt: DateTime.parse('2025-01-02T00:00:00Z'),
          audioUrl: 'https://example.com/e2.mp3',
          transcriptionStatus: TranscriptionStatus.ready,
        ),
      ],
      nextCursor: null,
    );
  }

  @override
  Future<EpisodeDetailEnvelope> getEpisode(String episodeId) async {
    await episodeGates[episodeId]?.future;
    final pending = episodeId == 'pending';
    return EpisodeDetailEnvelope(
      episode: EpisodeDetail(
        id: episodeId,
        sourceId: 'src1',
        sourceName: 'Demo',
        guid: 'guid-$episodeId',
        title: 'Episode $episodeId',
        description: 'description',
        publishedAt: DateTime.parse('2025-01-01T00:00:00Z'),
        audioUrl: 'https://example.com/$episodeId.mp3',
        transcriptionStatus:
            pending ? TranscriptionStatus.pending : TranscriptionStatus.ready,
        durationSec: 900,
      ),
      transcriptionStatus:
          pending ? TranscriptionStatus.pending : TranscriptionStatus.ready,
    );
  }

  @override
  Future<TranscriptionResult> transcribeVoiceFile(String audioPath) async {
    transcriptionCalls += 1;
    await transcriptionGate?.future;
    return TranscriptionResult(text: 'What was discussed?', durationMs: 1500);
  }

  @override
  Future<QaResponse> askQuestion({
    required String questionText,
    String? episodeId,
    int topK = 5,
  }) async {
    questionCalls += 1;
    lastQuestionEpisode = episodeId;
    lastQuestionText = questionText;
    await questionGate?.future;
    if (failQuestion) throw Exception('question unavailable');
    if (refuseAnswer) {
      return QaResponse(
        answerText:
            'I do not have enough transcript evidence to answer that confidently.',
        citations: const <Citation>[],
        grounded: false,
        refusalReason: 'insufficient_retrieval_confidence',
      );
    }

    return QaResponse(
      answerText: 'The host discussed architecture and citations.',
      citations: [
        Citation(
          segmentId: 'seg1',
          episodeId: episodeId ?? 'ep1',
          episodeTitle: 'Episode',
          startSec: 120,
          endSec: 140,
          text: 'Architecture and citations were discussed.',
          score: 0.88,
        ),
      ],
      grounded: true,
    );
  }

  @override
  Future<SynthesizedAudio> synthesize(String text) async {
    synthesisCalls += 1;
    if (failSynthesis) throw Exception('speech unavailable');
    return SynthesizedAudio(
      audioBase64: base64Encode(Uint8List.fromList(<int>[1, 2, 3, 4])),
      mimeType: 'audio/wav',
    );
  }
}

class FakeRecorder implements VoiceRecorder {
  bool started = false;
  int stopCalls = 0;
  Completer<void>? startGate;

  @override
  Future<void> start() async {
    await startGate?.future;
    started = true;
  }

  @override
  Future<String?> stop() async {
    stopCalls += 1;
    started = false;
    return '/tmp/fake-question.m4a';
  }

  @override
  Future<void> dispose() async {
    return;
  }
}

class FakeAudioOutput implements AudioOutput {
  Duration? lastSeek;
  String? lastEpisodeUrl;
  int ttsCalls = 0;
  int stopCalls = 0;
  String? lastMimeType;
  bool failEpisodePlayback = false;
  Completer<void>? ttsGate;
  bool blockTts = false;
  Completer<void>? episodeGate;
  Completer<void>? stopGate;
  bool blockEpisode = false;

  @override
  Future<void> playEpisode(String url, {Duration? seekTo}) async {
    if (failEpisodePlayback) throw Exception('audio unavailable');
    lastEpisodeUrl = url;
    lastSeek = seekTo;
    if (blockEpisode) episodeGate = Completer<void>();
    await episodeGate?.future;
  }

  @override
  Future<void> seekEpisode(Duration position) async {
    lastSeek = position;
  }

  @override
  Future<void> playTtsBytes(Uint8List audioBytes,
      {String mimeType = 'audio/mpeg'}) async {
    ttsCalls += 1;
    lastMimeType = mimeType;
    if (blockTts) ttsGate = Completer<void>();
    await ttsGate?.future;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    if (ttsGate != null && !ttsGate!.isCompleted) ttsGate!.complete();
    if (episodeGate != null && !episodeGate!.isCompleted) {
      episodeGate!.complete();
    }
    await stopGate?.future;
  }

  @override
  Future<void> dispose() async {
    return;
  }
}

void main() {
  group('PodcastController', () {
    test('library list renders paginated episodes via controller pagination',
        () async {
      final api = FakeApi();
      final controller = PodcastController(
        api: api,
        recorder: FakeRecorder(),
        audioOutput: FakeAudioOutput(),
      );

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
      final api = FakeApi();
      final controller = PodcastController(
        api: api,
        recorder: FakeRecorder(),
        audioOutput: FakeAudioOutput(),
      );

      await controller.selectEpisode('ep1');
      final seenStates = <VoiceState>[];
      controller.addListener(() {
        seenStates.add(controller.voiceState);
      });

      await controller.startRecording();
      await controller.stopRecordingAndAsk();

      expect(controller.voiceState, VoiceState.idle);
      expect(seenStates.contains(VoiceState.recording), true);
      expect(seenStates.contains(VoiceState.processing), true);
      expect(seenStates.contains(VoiceState.speaking), true);
    });

    test('citation tap seeks player to expected timestamp', () async {
      final api = FakeApi();
      final audio = FakeAudioOutput();
      final controller = PodcastController(
        api: api,
        recorder: FakeRecorder(),
        audioOutput: audio,
      );

      await controller.selectEpisode('ep1');
      await controller.playCitation(
        Citation(
          segmentId: 'seg1',
          episodeId: 'ep1',
          episodeTitle: 'Episode 1',
          startSec: 95,
          endSec: 102,
          text: 'citation text',
          score: 0.8,
        ),
      );

      expect(audio.lastEpisodeUrl, 'https://example.com/ep1.mp3');
      expect(audio.lastSeek, const Duration(seconds: 95));
    });

    test('handles pending transcript, network failure, and refusal response',
        () async {
      final api = FakeApi();
      final controller = PodcastController(
        api: api,
        recorder: FakeRecorder(),
        audioOutput: FakeAudioOutput(),
      );

      await controller.selectEpisode('pending');
      expect(controller.isEpisodeReady, false);

      await controller.startRecording();
      expect(controller.voiceState, VoiceState.idle);

      api.throwOnList = true;
      await controller.loadInitialEpisodes();
      expect(controller.errorMessage, isNotNull);

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
      final controller = PodcastController(
          api: api, recorder: recorder, audioOutput: FakeAudioOutput());
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

    test('changing episode clears old answer and citations', () async {
      final controller = PodcastController(
          api: FakeApi(),
          recorder: FakeRecorder(),
          audioOutput: FakeAudioOutput());
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('What was discussed?');
      expect(controller.latestResponse, isNotNull);
      expect(controller.lastQuestionText, 'What was discussed?');
      await controller.selectEpisode('ep2');
      expect(controller.latestResponse, isNull);
      expect(controller.lastQuestionText, isNull);
      expect(controller.selectedEpisode!.episode.id, 'ep2');
    });

    test('only submitting a voice recording clears the previous conversation',
        () async {
      final api = FakeApi()..transcriptionGate = Completer<void>();
      final recorder = FakeRecorder();
      final controller = PodcastController(
          api: api, recorder: recorder, audioOutput: FakeAudioOutput());
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Previous question');
      final previousAnswer = controller.latestResponse;

      await controller.startRecording();
      expect(controller.latestResponse, same(previousAnswer));
      expect(controller.lastQuestionText, 'Previous question');
      await controller.cancelRecording();
      expect(controller.latestResponse, same(previousAnswer));
      expect(controller.lastQuestionText, 'Previous question');

      recorder.startGate = Completer<void>();
      final starting = controller.startRecording();
      final earlyRelease = controller.stopRecordingAndAsk();
      recorder.startGate!.complete();
      await Future.wait([starting, earlyRelease]);
      expect(controller.latestResponse, same(previousAnswer));
      expect(controller.lastQuestionText, 'Previous question');
      expect(api.transcriptionCalls, 0);

      await controller.startRecording();
      final submitting = controller.stopRecordingAndAsk();
      expect(controller.voiceState, VoiceState.processing);
      expect(controller.latestResponse, isNull);
      expect(controller.lastQuestionText, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(api.transcriptionCalls, 1);
      expect(controller.latestResponse, isNull);
      expect(controller.lastQuestionText, isNull);

      api.transcriptionGate!.complete();
      await submitting;
      expect(controller.lastQuestionText, 'What was discussed?');
      expect(controller.latestResponse, isNotNull);
      expect(controller.voiceState, VoiceState.idle);
    });

    test('episode playback starts at zero and stays stoppable until completion',
        () async {
      final audio = FakeAudioOutput()..blockEpisode = true;
      final controller = PodcastController(
          api: FakeApi(), recorder: FakeRecorder(), audioOutput: audio);
      await controller.selectEpisode('ep1');
      final playing = controller.playSelectedEpisode();
      await Future<void>.delayed(Duration.zero);
      expect(audio.lastEpisodeUrl, 'https://example.com/ep1.mp3');
      expect(audio.lastSeek, Duration.zero);
      expect(controller.isPlayingEpisode, true);
      expect(controller.canStopAudio, true);
      await controller.stopAudio();
      await playing;
      expect(controller.isPlayingEpisode, false);
      expect(controller.canStopAudio, false);
    });

    test('changing episode stops its playback', () async {
      final audio = FakeAudioOutput()..blockEpisode = true;
      final controller = PodcastController(
          api: FakeApi(), recorder: FakeRecorder(), audioOutput: audio);
      await controller.selectEpisode('ep1');
      final playing = controller.playSelectedEpisode();
      await Future<void>.delayed(Duration.zero);
      await controller.selectEpisode('ep2');
      await playing;
      expect(controller.selectedEpisode!.episode.id, 'ep2');
      expect(controller.isPlayingEpisode, false);
      expect(controller.canStopAudio, false);
    });

    test('recording stops episode playback before opening the microphone',
        () async {
      final audio = FakeAudioOutput()..blockEpisode = true;
      final recorder = FakeRecorder();
      final controller = PodcastController(
          api: FakeApi(), recorder: recorder, audioOutput: audio);
      await controller.selectEpisode('ep1');
      final playing = controller.playSelectedEpisode();
      await Future<void>.delayed(Duration.zero);
      await controller.startRecording();
      await playing;
      expect(recorder.started, true);
      expect(controller.isPlayingEpisode, false);
      expect(controller.canStopAudio, false);
      await controller.cancelRecording();
    });

    test('citation highlight follows playback and clears on stop', () async {
      final audio = FakeAudioOutput()..blockEpisode = true;
      final controller = PodcastController(
          api: FakeApi(), recorder: FakeRecorder(), audioOutput: audio);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      final citation = controller.latestResponse!.citations.first;
      final playing = controller.playCitation(citation);
      await Future<void>.delayed(Duration.zero);
      expect(controller.activeCitationId, citation.segmentId);
      expect(controller.isPlayingCitation, true);
      expect(controller.isPlayingEpisode, false);
      await controller.stopAudio();
      await playing;
      expect(controller.activeCitationId, isNull);
      expect(controller.isPlayingCitation, false);
    });

    test('a stop during episode startup prevents late playback', () async {
      final audio = FakeAudioOutput();
      final controller = PodcastController(
          api: FakeApi(), recorder: FakeRecorder(), audioOutput: audio);
      await controller.selectEpisode('ep1');
      audio.stopGate = Completer<void>();
      final playing = controller.playSelectedEpisode();
      final stopping = controller.stopAudio();
      audio.stopGate!.complete();
      await Future.wait([playing, stopping]);
      expect(audio.lastEpisodeUrl, isNull);
      expect(controller.isPlayingEpisode, false);
    });

    test('episode playback failure is dismissible without losing selection',
        () async {
      final audio = FakeAudioOutput()..failEpisodePlayback = true;
      final controller = PodcastController(
          api: FakeApi(), recorder: FakeRecorder(), audioOutput: audio);
      await controller.selectEpisode('ep1');
      await controller.playSelectedEpisode();
      expect(controller.errorMessage, contains('Unable to play episode'));
      expect(controller.isPlayingEpisode, false);
      controller.dismissError();
      expect(controller.errorMessage, isNull);
      expect(controller.selectedEpisode!.episode.id, 'ep1');
    });

    test('submitted question is visible while the answer is pending', () async {
      final api = FakeApi()..questionGate = Completer<void>();
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
      await controller.selectEpisode('ep1');
      final answer = controller.submitTypedQuestion('  What was discussed?  ');
      expect(controller.lastQuestionText, 'What was discussed?');
      expect(controller.latestResponse, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(api.lastQuestionText, controller.lastQuestionText);
      api.questionGate!.complete();
      await answer;
    });

    test('voice questions retain their recognized text even if answering fails',
        () async {
      final api = FakeApi()..failQuestion = true;
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
      await controller.selectEpisode('ep1');
      await controller.startRecording();
      await controller.stopRecordingAndAsk();
      expect(controller.lastQuestionText, 'What was discussed?');
      expect(api.lastQuestionText, controller.lastQuestionText);
      expect(controller.latestResponse, isNull);
      expect(controller.errorMessage, contains('Failed to answer question'));
    });

    test('citation resolves its own episode and preserves fractional timestamp',
        () async {
      final audio = FakeAudioOutput();
      final controller = PodcastController(
          api: FakeApi(), recorder: FakeRecorder(), audioOutput: audio);
      await controller.selectEpisode('ep2');
      await controller.playCitation(Citation(
          segmentId: 'seg1',
          episodeId: 'ep1',
          episodeTitle: 'First',
          startSec: 12.45,
          endSec: 20,
          text: 'Evidence',
          score: 0.9));
      expect(audio.lastEpisodeUrl, 'https://example.com/ep1.mp3');
      expect(audio.lastSeek, const Duration(milliseconds: 12450));
      expect(controller.selectedEpisode!.episode.id, 'ep2');
    });

    test(
        'overlapping questions and episode changes cannot reassign a pending answer',
        () async {
      final api = FakeApi()..questionGate = Completer<void>();
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
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
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
      await controller.selectEpisode('pending');
      await controller.submitTypedQuestion('Question');
      expect(api.questionCalls, 0);
      expect(controller.canAskQuestion, false);
    });

    test('text only mode skips synthesis and still returns citations',
        () async {
      final api = FakeApi();
      final audio = FakeAudioOutput();
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: audio);
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
      final controller = PodcastController(
          api: FakeApi(), recorder: FakeRecorder(), audioOutput: audio);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      expect(audio.lastMimeType, 'audio/wav');
    });

    test('speech failure preserves the text answer', () async {
      final api = FakeApi()..failSynthesis = true;
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      expect(controller.latestResponse!.grounded, true);
      expect(controller.errorMessage, contains('Text answer is ready'));
      expect(controller.voiceState, VoiceState.idle);
    });

    test('stop audio unlocks questions while speech is playing', () async {
      final audio = FakeAudioOutput()..blockTts = true;
      final controller = PodcastController(
          api: FakeApi(), recorder: FakeRecorder(), audioOutput: audio);
      await controller.selectEpisode('ep1');
      final answer = controller.submitTypedQuestion('Question');
      await Future<void>.delayed(Duration.zero);
      expect(controller.voiceState, VoiceState.speaking);
      expect(controller.canStopAudio, true);
      await controller.stopAudio();
      await answer;
      expect(controller.canAskQuestion, true);
      expect(controller.latestResponse, isNotNull);
    });

    test('citation playback errors appear in the app instead of escaping',
        () async {
      final audio = FakeAudioOutput()..failEpisodePlayback = true;
      final controller = PodcastController(
          api: FakeApi(), recorder: FakeRecorder(), audioOutput: audio);
      await controller.selectEpisode('ep1');
      await controller.submitTypedQuestion('Question');
      await controller.playCitation(controller.latestResponse!.citations.first);
      expect(controller.errorMessage, contains('Unable to play citation'));
      expect(controller.isPlayingCitation, false);
    });

    test('empty refresh clears a previously selected episode', () async {
      final api = FakeApi();
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
      await controller.loadInitialEpisodes();
      api.emptyLibrary = true;
      await controller.loadInitialEpisodes();
      expect(controller.episodes, isEmpty);
      expect(controller.selectedEpisode, isNull);
      expect(controller.canAskQuestion, false);
    });

    test('late episode detail response cannot overwrite a newer selection',
        () async {
      final api = FakeApi();
      final olderResponse = Completer<void>();
      api.episodeGates['ep1'] = olderResponse;
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
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
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
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
      final controller = PodcastController(
          api: api, recorder: recorder, audioOutput: FakeAudioOutput());
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
      final controller = PodcastController(
          api: api, recorder: recorder, audioOutput: FakeAudioOutput());
      await controller.selectEpisode('ep1');
      final starting = controller.startRecording();
      final stopping = controller.stopRecordingAndAsk();
      await Future<void>.delayed(Duration.zero);
      startup.completeError(Exception('Microphone permission denied'));
      await Future.wait([starting, stopping]);
      expect(recorder.stopCalls, 0);
      expect(api.transcriptionCalls, 0);
      expect(controller.errorMessage, contains('Unable to start recording'));
      expect(controller.voiceState, VoiceState.idle);
    });
  });
}
