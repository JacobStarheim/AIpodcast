import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'audio_output.dart';
import 'models.dart';
import 'podcast_api.dart';
import 'voice_recorder.dart';

enum VoiceState { idle, starting, recording, processing, speaking }

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
  Future<void>? _recordingStart;
  int _selectionGeneration = 0;
  int _questionGeneration = 0;
  int _playbackGeneration = 0;
  bool _closed = false;

  List<EpisodeSummary> get episodes => List.unmodifiable(_episodes);
  EpisodeDetailEnvelope? selectedEpisode;
  QaResponse? latestResponse;
  String? lastQuestionText;
  VoiceState voiceState = VoiceState.idle;
  String? errorMessage;
  String? nextCursor;
  bool isLoadingEpisodes = false;
  bool isLoadingMore = false;
  bool isSelectingEpisode = false;
  bool isPlayingEpisode = false;
  bool isPlayingCitation = false;
  String? activeCitationId;
  bool readAnswersAloud = true;

  bool get hasMoreEpisodes => nextCursor != null;
  bool get isEpisodeReady =>
      selectedEpisode?.transcriptionStatus == TranscriptionStatus.ready;
  bool get canAskQuestion =>
      !_closed && isEpisodeReady && voiceState == VoiceState.idle;
  bool get canSelectEpisode => !_closed && voiceState == VoiceState.idle;
  bool get canUsePushToTalk =>
      isEpisodeReady &&
      (voiceState == VoiceState.idle ||
          voiceState == VoiceState.starting ||
          voiceState == VoiceState.recording);
  bool get canStopAudio =>
      isPlayingEpisode ||
      isPlayingCitation ||
      voiceState == VoiceState.speaking;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void setReadAnswersAloud(bool value) {
    readAnswersAloud = value;
    _notify();
  }

  void dismissError() {
    errorMessage = null;
    _notify();
  }

  Future<void> loadInitialEpisodes() async {
    if (_closed || isLoadingEpisodes || !canSelectEpisode) return;
    isLoadingEpisodes = true;
    errorMessage = null;
    _notify();
    try {
      final page = await _api.listEpisodes(limit: 20);
      if (_closed) return;
      _episodes
        ..clear()
        ..addAll(page.items);
      nextCursor = page.nextCursor;
      if (_episodes.isNotEmpty) {
        await selectEpisode(_episodes.first.id, notify: false);
      } else {
        await stopAudio();
        selectedEpisode = null;
        latestResponse = null;
        lastQuestionText = null;
      }
    } catch (error) {
      errorMessage = 'Failed to load episodes: $error';
    } finally {
      isLoadingEpisodes = false;
      _notify();
    }
  }

  Future<void> loadMoreEpisodes() async {
    if (_closed || isLoadingMore || nextCursor == null) return;
    isLoadingMore = true;
    _notify();
    try {
      final page = await _api.listEpisodes(cursor: nextCursor, limit: 20);
      if (_closed) return;
      _episodes.addAll(page.items);
      nextCursor = page.nextCursor;
    } catch (error) {
      errorMessage = 'Failed to load more episodes: $error';
    } finally {
      isLoadingMore = false;
      _notify();
    }
  }

  Future<void> selectEpisode(String episodeId, {bool notify = true}) async {
    if (!canSelectEpisode) return;
    final generation = ++_selectionGeneration;
    selectedEpisode = null;
    latestResponse = null;
    lastQuestionText = null;
    errorMessage = null;
    isSelectingEpisode = true;
    if (notify) _notify();
    try {
      await stopAudio();
      final episode = await _api.getEpisode(episodeId);
      if (_closed || generation != _selectionGeneration) return;
      selectedEpisode = episode;
    } catch (error) {
      if (generation == _selectionGeneration) {
        errorMessage = 'Failed to load episode details: $error';
      }
    } finally {
      if (generation == _selectionGeneration) {
        isSelectingEpisode = false;
        if (notify) _notify();
      }
    }
  }

  Future<void> startRecording() async {
    if (!canAskQuestion) return;
    errorMessage = null;
    voiceState = VoiceState.starting;
    // Store the whole startup operation before yielding. A release while the
    // permission dialog is open must wait for startup and then stop recording.
    final start = _startRecorder();
    _recordingStart = start;
    _notify();
    try {
      await start;
      if (!_closed && voiceState == VoiceState.starting) {
        voiceState = VoiceState.recording;
        _notify();
      }
    } catch (error) {
      errorMessage = 'Unable to start recording: $error';
      voiceState = VoiceState.idle;
      _notify();
    } finally {
      if (identical(_recordingStart, start)) _recordingStart = null;
    }
  }

  Future<void> _startRecorder() async {
    await stopAudio();
    if (!_closed) await _recorder.start();
  }

  Future<void> stopRecordingAndAsk() async {
    if (voiceState == VoiceState.starting) {
      // A release before permission/startup completes contains no question.
      // Finish startup and discard the resulting empty recording.
      await cancelRecording();
      return;
    }
    if (voiceState != VoiceState.recording) return;
    voiceState = VoiceState.processing;
    latestResponse = null;
    lastQuestionText = null;
    _notify();
    try {
      await _recordingStart;
      if (_closed) return;
      final audioPath = await _recorder.stop();
      if (audioPath == null || audioPath.isEmpty) {
        throw Exception('No recorded audio was produced.');
      }
      final transcription = await _api.transcribeVoiceFile(audioPath);
      if (_closed) return;
      if (transcription.text.trim().isEmpty) {
        throw Exception('Transcription returned empty text.');
      }
      await _answerQuestion(transcription.text);
    } catch (error) {
      errorMessage = 'Failed to process voice question: $error';
      voiceState = VoiceState.idle;
      _notify();
    }
  }

  Future<void> cancelRecording() async {
    if (voiceState != VoiceState.starting &&
        voiceState != VoiceState.recording) {
      return;
    }
    voiceState = VoiceState.processing;
    _notify();
    try {
      try {
        await _recordingStart;
      } catch (_) {
        // startRecording already reports permission/startup failures.
        return;
      }
      if (_closed) return;
      await _recorder.stop();
    } catch (error) {
      errorMessage = 'Unable to stop recording: $error';
    } finally {
      voiceState = VoiceState.idle;
      _notify();
    }
  }

  Future<void> submitTypedQuestion(String questionText) async {
    final trimmed = questionText.trim();
    if (trimmed.isEmpty || !canAskQuestion) return;
    voiceState = VoiceState.processing;
    _notify();
    await _answerQuestion(trimmed);
  }

  Future<void> _answerQuestion(String questionText) async {
    final episodeId = selectedEpisode?.episode.id;
    if (_closed || episodeId == null) return;
    final generation = ++_questionGeneration;
    errorMessage = null;
    latestResponse = null;
    lastQuestionText = questionText;
    _notify();
    try {
      await stopAudio();
      if (_closed || generation != _questionGeneration) return;
      final qa = await _api.askQuestion(
        questionText: questionText,
        episodeId: episodeId,
        topK: 5,
      );
      if (_closed || generation != _questionGeneration) return;
      latestResponse = qa;
      // Render the answer immediately, even if speech generation is slow.
      _notify();
      if (readAnswersAloud && qa.grounded && qa.answerText.trim().isNotEmpty) {
        try {
          final synthesized = await _api.synthesize(qa.answerText);
          if (_closed || generation != _questionGeneration) return;
          final bytes = base64Decode(synthesized.audioBase64);
          voiceState = VoiceState.speaking;
          _notify();
          await _audioOutput.playTtsBytes(bytes,
              mimeType: synthesized.mimeType);
        } catch (_) {
          if (!_closed && generation == _questionGeneration) {
            errorMessage = 'Text answer is ready, but voice playback failed.';
          }
        }
      }
    } catch (error) {
      if (generation == _questionGeneration) {
        errorMessage = 'Failed to answer question: $error';
      }
    } finally {
      if (generation == _questionGeneration) {
        voiceState = VoiceState.idle;
        _notify();
      }
    }
  }

  Future<void> playSelectedEpisode() async {
    final episode = selectedEpisode?.episode;
    if (_closed ||
        episode == null ||
        (voiceState != VoiceState.idle && voiceState != VoiceState.speaking)) {
      return;
    }
    final stopping = stopAudio();
    final generation = _playbackGeneration;
    try {
      await stopping;
      if (_closed || generation != _playbackGeneration) return;
      isPlayingEpisode = true;
      errorMessage = null;
      _notify();
      await _audioOutput.playEpisode(episode.audioUrl, seekTo: Duration.zero);
    } catch (error) {
      if (generation == _playbackGeneration) {
        errorMessage = 'Unable to play episode: $error';
      }
    } finally {
      if (generation == _playbackGeneration) {
        isPlayingEpisode = false;
        _notify();
      }
    }
  }

  Future<void> playCitation(Citation citation) async {
    if (_closed ||
        (voiceState != VoiceState.idle && voiceState != VoiceState.speaking)) {
      return;
    }
    final stopping = stopAudio();
    final generation = _playbackGeneration;
    try {
      await stopping;
      if (_closed || generation != _playbackGeneration) return;
      isPlayingCitation = true;
      activeCitationId = citation.segmentId;
      errorMessage = null;
      _notify();
      final episode = selectedEpisode?.episode.id == citation.episodeId
          ? selectedEpisode!.episode
          : (await _api.getEpisode(citation.episodeId)).episode;
      if (_closed || generation != _playbackGeneration) return;
      await _audioOutput.playEpisode(
        episode.audioUrl,
        seekTo: Duration(milliseconds: (citation.startSec * 1000).round()),
      );
    } catch (error) {
      if (generation == _playbackGeneration) {
        errorMessage = 'Unable to play citation: $error';
      }
    } finally {
      if (generation == _playbackGeneration) {
        isPlayingCitation = false;
        activeCitationId = null;
        _notify();
      }
    }
  }

  Future<void> stopAudio() async {
    ++_playbackGeneration;
    if (voiceState == VoiceState.speaking) {
      ++_questionGeneration;
      voiceState = VoiceState.idle;
    }
    isPlayingEpisode = false;
    isPlayingCitation = false;
    activeCitationId = null;
    await _audioOutput.stop();
    _notify();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_questionGeneration;
    ++_playbackGeneration;
    try {
      await _recordingStart;
    } catch (_) {
      // The startup error is already surfaced by startRecording.
    }
    await _recorder.dispose();
    await _audioOutput.dispose();
  }
}
