import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'audio_output.dart';
import 'conversation_store.dart';
import 'models.dart';
import 'playback_position_store.dart';
import 'podcast_api.dart';
import 'sources_controller.dart';
import 'voice_recorder.dart';

export 'conversation_store.dart' show ConversationTurn;
export 'models.dart' show AnswerStage;

// The controller is one object for the UI, written in focused parts that
// share the state below:
part 'controller/library.dart'; // episode list, selection, transcription
part 'controller/playback.dart'; // the episode player and positions
part 'controller/conversation.dart'; // questions, answers and speech

enum VoiceState { idle, starting, recording, processing, speaking }

/// Where answers come from: the selected episode or every ready episode.
enum QuestionScope { episode, library }

enum PlayerStatus { stopped, loading, playing, paused }

/// The part of the app an error belongs to, so it is shown next to it.
enum ErrorKind {
  library,
  episode,
  transcription,
  playback,
  recording,
  question,
  speech,
}

class AppError {
  const AppError(this.kind, this.message);

  final ErrorKind kind;

  /// A short message for the listener, never a raw response body.
  final String message;

  bool get belongsToConversation =>
      kind == ErrorKind.recording ||
      kind == ErrorKind.question ||
      kind == ErrorKind.speech;
}

class PlaybackProgress {
  const PlaybackProgress({this.position = Duration.zero, this.duration});

  final Duration position;
  final Duration? duration;
}

/// The library, the player and the conversation of the home screen.
class PodcastController extends _ControllerCore
    with _Playback, _Conversation, _Library {
  PodcastController({
    required PodcastApi api,
    required super.recorder,
    required super.audioOutput,
    PlaybackPositionStore? positionStore,
    ConversationStore? conversationStore,
    super.pollInterval,
    super.searchDebounce,
  }) : super(
          api: api,
          positions: positionStore ?? MemoryPlaybackPositionStore(),
          conversations: conversationStore ?? MemoryConversationStore(),
        ) {
    sources = SourcesController(
      api: api,
      pollInterval: pollInterval,
      searchDebounce: searchDebounce,
      onImportFinished: () => unawaited(_reloadEpisodes()),
    )..addListener(_onSourcesChanged);
    _listenToPlayer();
    _libraryRestored = _restoreLibraryConversation();
  }

  static const pageSize = 20;

  /// Earlier grounded turns sent with a follow-up question.
  static const historyLimit = 6;

  /// Passages retrieved per question; matches the API default.
  static const topK = 10;

  /// Positions this close to the end count as finished.
  static const finishedMargin = Duration(seconds: 5);

  Future<void> close() async {
    if (_closed) return;
    final saving = _saveLoadedPosition(force: true);
    _closed = true;
    ++_questionGeneration;
    ++_playbackGeneration;
    ++_listGeneration;
    _queryDebounce?.cancel();
    _pollTimer?.cancel();
    sources.close();
    await _stopListeningToPlayer();
    try {
      await _recordingStart;
    } catch (_) {
      // The startup error is already surfaced by startRecording.
    }
    await saving;
    await _recorder.dispose();
    await _audioOutput.dispose();
  }

  @override
  void dispose() {
    _closed = true;
    _queryDebounce?.cancel();
    _pollTimer?.cancel();
    unawaited(_stopListeningToPlayer());
    sources
      ..removeListener(_onSourcesChanged)
      ..dispose();
    selectedProgress.dispose();
    streamingAnswer.dispose();
    super.dispose();
  }
}

/// State and helpers that more than one part reads or changes.
abstract class _ControllerCore extends ChangeNotifier {
  _ControllerCore({
    required PodcastApi api,
    required VoiceRecorder recorder,
    required AudioOutput audioOutput,
    required PlaybackPositionStore positions,
    required ConversationStore conversations,
    this.pollInterval = const Duration(seconds: 5),
    this.searchDebounce = const Duration(milliseconds: 400),
  })  : _api = api,
        _recorder = recorder,
        _audioOutput = audioOutput,
        _positions = positions,
        _conversationStore = conversations;

  final PodcastApi _api;
  final VoiceRecorder _recorder;
  final AudioOutput _audioOutput;
  final PlaybackPositionStore _positions;
  final ConversationStore _conversationStore;
  final Duration pollInterval;
  final Duration searchDebounce;
  late final SourcesController sources;
  bool _closed = false;
  AppError? error;

  // Episodes: the library part loads them, playback refreshes their links.
  final List<EpisodeSummary> _episodes = <EpisodeSummary>[];
  final Map<String, EpisodeDetail> _episodeCache = {};
  EpisodeDetailEnvelope? selectedEpisode;
  bool isSelectingEpisode = false;

  // Questions: the conversation part runs them; playing the episode
  // interrupts a spoken answer.
  QuestionScope scope = QuestionScope.episode;
  VoiceState voiceState = VoiceState.idle;
  bool isPreparingSpeech = false;
  int _questionGeneration = 0;
  bool _positionDismissed = false;
  Duration? _capturedPosition;
  bool _resumeAfterQuestion = false;

  /// Position and length of the selected episode, updated while it plays.
  final ValueNotifier<PlaybackProgress> selectedProgress =
      ValueNotifier(const PlaybackProgress());

  String? get errorMessage => error?.message;

  bool get isEpisodeReady =>
      selectedEpisode?.transcriptionStatus == TranscriptionStatus.ready;

  /// Whether any episode in the library can answer questions.
  bool get hasReadyEpisodes =>
      isEpisodeReady ||
      _episodes.any((episode) =>
          episode.transcriptionStatus == TranscriptionStatus.ready) ||
      sources.readyEpisodeCount > 0;

  bool get isScopeReady =>
      scope == QuestionScope.library ? hasReadyEpisodes : isEpisodeReady;
  bool get canAskQuestion =>
      !_closed && isScopeReady && voiceState == VoiceState.idle;
  bool get canSelectEpisode => !_closed && voiceState == VoiceState.idle;
  bool get canChangeConversation => !_closed && voiceState == VoiceState.idle;
  bool get canUsePushToTalk =>
      !_closed &&
      isScopeReady &&
      (voiceState == VoiceState.idle ||
          voiceState == VoiceState.starting ||
          voiceState == VoiceState.recording);

  /// Play, pause, seek and citations are unavailable while a question is
  /// being recorded or answered; that flow pauses and resumes playback.
  bool get canControlPlayback =>
      !_closed &&
      (voiceState == VoiceState.idle || voiceState == VoiceState.speaking);
  bool get isSpeaking => voiceState == VoiceState.speaking;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _setSelectedProgress(PlaybackProgress progress) {
    if (!_closed) selectedProgress.value = progress;
  }

  void _fail(ErrorKind kind, Object cause, String fallback) {
    error = AppError(kind, describeError(cause, fallback: fallback));
  }

  void _clearErrors(bool Function(AppError error) test) {
    final current = error;
    if (current != null && test(current)) error = null;
  }

  void dismissError() {
    error = null;
    _notify();
  }

  Duration? _durationOf(EpisodeSummary episode) {
    final seconds = episode.durationSec;
    return seconds == null || seconds <= 0 ? null : Duration(seconds: seconds);
  }

  void _replaceListed(EpisodeSummary episode) {
    final index = _episodes.indexWhere((item) => item.id == episode.id);
    if (index >= 0) _episodes[index] = episode;
  }

  void _applySummary(EpisodeSummary summary) {
    _replaceListed(summary);
    final selected = selectedEpisode;
    if (selected != null && selected.episode.id == summary.id) {
      final episode = selected.episode.copyWithStatus(
          summary.transcriptionStatus,
          transcriptionError: summary.transcriptionError);
      selectedEpisode = EpisodeDetailEnvelope(
          episode: episode, transcriptionStatus: summary.transcriptionStatus);
    }
  }

  /// Keeps the list, the selection and the cache in step with fresh details
  /// (status, and a renewed playback link).
  void _applyDetail(EpisodeDetailEnvelope envelope) {
    var episode = envelope.episode;
    if (episode.transcriptionStatus != envelope.transcriptionStatus) {
      episode = episode.copyWithStatus(envelope.transcriptionStatus,
          transcriptionError: episode.transcriptionError);
    }
    _replaceListed(episode);
    _episodeCache[episode.id] = episode;
    if (selectedEpisode?.episode.id == episode.id) {
      selectedEpisode = EpisodeDetailEnvelope(
          episode: episode, transcriptionStatus: envelope.transcriptionStatus);
    }
  }
}
