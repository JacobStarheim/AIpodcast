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

  @override
  Future<EpisodePage> listEpisodes({String? cursor, int limit = 20}) async {
    if (throwOnList) {
      throw Exception('network failure');
    }

    listCalls += 1;
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
    return TranscriptionResult(text: 'What was discussed?', durationMs: 1500);
  }

  @override
  Future<QaResponse> askQuestion({
    required String questionText,
    String? episodeId,
    int topK = 5,
  }) async {
    if (refuseAnswer) {
      return QaResponse(
        answerText: 'I do not have enough transcript evidence to answer that confidently.',
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
    return SynthesizedAudio(
      audioBase64: base64Encode(Uint8List.fromList(<int>[1, 2, 3, 4])),
      mimeType: 'audio/mpeg',
    );
  }
}

class FakeRecorder implements VoiceRecorder {
  bool started = false;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<String?> stop() async {
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

  @override
  Future<void> playEpisode(String url, {Duration? seekTo}) async {
    lastEpisodeUrl = url;
    lastSeek = seekTo;
  }

  @override
  Future<void> seekEpisode(Duration position) async {
    lastSeek = position;
  }

  @override
  Future<void> playTtsBytes(Uint8List mp3Bytes) async {
    ttsCalls += 1;
  }

  @override
  Future<void> dispose() async {
    return;
  }
}

void main() {
  group('PodcastController', () {
    test('library list renders paginated episodes via controller pagination', () async {
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

    test('voice capture state machine transitions idle -> recording -> processing -> speaking -> idle', () async {
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

    test('handles pending transcript, network failure, and refusal response', () async {
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
      expect(controller.latestResponse!.refusalReason, 'insufficient_retrieval_confidence');
    });
  });
}
