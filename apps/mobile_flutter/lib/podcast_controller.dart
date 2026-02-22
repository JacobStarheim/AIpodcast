import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'audio_output.dart';
import 'models.dart';
import 'podcast_api.dart';
import 'voice_recorder.dart';

enum VoiceState { idle, recording, processing, speaking }

class PodcastController extends ChangeNotifier {
  PodcastController({
    required PodcastApi api,
    required VoiceRecorder recorder,
    required AudioOutput audioOutput,
  })  : _api = api,
        _recorder = recorder,
        _audioOutput = audioOutput;

  final PodcastApi _api;
  final VoiceRecorder _recorder;
  final AudioOutput _audioOutput;

  final List<EpisodeSummary> _episodes = <EpisodeSummary>[];

  List<EpisodeSummary> get episodes => List.unmodifiable(_episodes);

  EpisodeDetailEnvelope? selectedEpisode;
  QaResponse? latestResponse;

  VoiceState voiceState = VoiceState.idle;
  String? errorMessage;
  String? nextCursor;
  bool isLoadingEpisodes = false;
  bool isLoadingMore = false;

  bool get hasMoreEpisodes => nextCursor != null;

  bool get isEpisodeReady =>
      selectedEpisode?.transcriptionStatus == TranscriptionStatus.ready;

  bool get canUsePushToTalk =>
      isEpisodeReady &&
      (voiceState == VoiceState.idle || voiceState == VoiceState.recording);

  Future<void> loadInitialEpisodes() async {
    isLoadingEpisodes = true;
    errorMessage = null;
    notifyListeners();

    try {
      final page = await _api.listEpisodes(limit: 20);
      _episodes
        ..clear()
        ..addAll(page.items);
      nextCursor = page.nextCursor;

      if (_episodes.isNotEmpty) {
        await selectEpisode(_episodes.first.id, notify: false);
      }
    } catch (error) {
      errorMessage = 'Failed to load episodes: $error';
    } finally {
      isLoadingEpisodes = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreEpisodes() async {
    if (isLoadingMore || nextCursor == null) {
      return;
    }

    isLoadingMore = true;
    notifyListeners();

    try {
      final page = await _api.listEpisodes(cursor: nextCursor, limit: 20);
      _episodes.addAll(page.items);
      nextCursor = page.nextCursor;
    } catch (error) {
      errorMessage = 'Failed to load more episodes: $error';
    } finally {
      isLoadingMore = false;
      notifyListeners();
    }
  }

  Future<void> selectEpisode(String episodeId, {bool notify = true}) async {
    try {
      final episode = await _api.getEpisode(episodeId);
      selectedEpisode = episode;
      errorMessage = null;
    } catch (error) {
      errorMessage = 'Failed to load episode details: $error';
    }

    if (notify) {
      notifyListeners();
    }
  }

  Future<void> startRecording() async {
    if (!isEpisodeReady || voiceState != VoiceState.idle) {
      return;
    }

    try {
      errorMessage = null;
      await _recorder.start();
      voiceState = VoiceState.recording;
      notifyListeners();
    } catch (error) {
      errorMessage = 'Unable to start recording: $error';
      voiceState = VoiceState.idle;
      notifyListeners();
    }
  }

  Future<void> stopRecordingAndAsk() async {
    if (voiceState != VoiceState.recording) {
      return;
    }

    voiceState = VoiceState.processing;
    notifyListeners();

    try {
      final audioPath = await _recorder.stop();
      if (audioPath == null || audioPath.isEmpty) {
        throw Exception('No recorded audio was produced.');
      }

      final transcription = await _api.transcribeVoiceFile(audioPath);
      if (transcription.text.trim().isEmpty) {
        throw Exception('Transcription returned empty text.');
      }

      await submitTypedQuestion(transcription.text, fromRecording: true);
    } catch (error) {
      errorMessage = 'Failed to process voice question: $error';
      voiceState = VoiceState.idle;
      notifyListeners();
    }
  }

  Future<void> submitTypedQuestion(
    String questionText, {
    bool fromRecording = false,
  }) async {
    final trimmed = questionText.trim();
    if (trimmed.isEmpty || selectedEpisode == null) {
      return;
    }

    if (!fromRecording) {
      voiceState = VoiceState.processing;
      notifyListeners();
    }

    try {
      final qa = await _api.askQuestion(
        questionText: trimmed,
        episodeId: selectedEpisode?.episode.id,
        topK: 5,
      );

      latestResponse = qa;

      if (!qa.grounded || qa.answerText.trim().isEmpty) {
        voiceState = VoiceState.idle;
        notifyListeners();
        return;
      }

      try {
        final synthesized = await _api.synthesize(qa.answerText);
        final bytes = base64Decode(synthesized.audioBase64);

        voiceState = VoiceState.speaking;
        notifyListeners();

        await _audioOutput.playTtsBytes(bytes);
      } catch (_) {
        errorMessage = 'Text answer is ready, but voice playback failed.';
      }

      voiceState = VoiceState.idle;
      notifyListeners();
    } catch (error) {
      errorMessage = 'Failed to answer question: $error';
      voiceState = VoiceState.idle;
      notifyListeners();
    }
  }

  Future<void> playCitation(Citation citation) async {
    final episode = selectedEpisode?.episode;
    if (episode == null) {
      return;
    }

    await _audioOutput.playEpisode(
      episode.audioUrl,
      seekTo: Duration(seconds: citation.startSec.round()),
    );
  }

  Future<void> close() async {
    await _recorder.dispose();
    await _audioOutput.dispose();
  }
}
