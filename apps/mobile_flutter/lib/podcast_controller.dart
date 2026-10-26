import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'audio_output.dart';
import 'models.dart';
import 'playback_position_store.dart';
import 'podcast_api.dart';
import 'sources_controller.dart';
import 'voice_recorder.dart';

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

class ConversationTurn {
  const ConversationTurn({
    required this.question,
    required this.response,
    this.positionSec,
  });

  final String question;
  final QaResponse response;

  /// Playback position the question referred to, if any.
  final double? positionSec;
}

class _NothingHeard implements Exception {
  const _NothingHeard();
}

const _nothingHeardMessage =
    'I didn’t catch that. Try speaking again, or type your question.';
const _questionFailedMessage =
    'Something interrupted that request. Please try again. You can also type your question.';
const _playbackFailedMessage =
    'This audio couldn’t play. Check your connection and try again.';
const _speechFailedMessage =
    'Your answer is ready to read. Spoken playback is unavailable right now.';

class PodcastController extends ChangeNotifier {
  PodcastController({
    required PodcastApi api,
    required VoiceRecorder recorder,
    required AudioOutput audioOutput,
    PlaybackPositionStore? positionStore,
    this.pollInterval = const Duration(seconds: 5),
    this.searchDebounce = const Duration(milliseconds: 400),
  })  : _api = api,
        _recorder = recorder,
        _audioOutput = audioOutput,
        _positions = positionStore ?? MemoryPlaybackPositionStore() {
    sources = SourcesController(
      api: api,
      pollInterval: pollInterval,
      searchDebounce: searchDebounce,
      onImportFinished: () => unawaited(_reloadEpisodes()),
    )..addListener(_onSourcesChanged);
    _progressSubscription = _audioOutput.episodeProgress
        .listen(_onProgress, onError: _onPlaybackError);
  }

  static const pageSize = 20;

  /// Earlier grounded turns sent with a follow-up question.
  static const historyLimit = 6;
  static const topK = 6;

  /// Positions this close to the end count as finished.
  static const finishedMargin = Duration(seconds: 5);
  static const _saveEvery = Duration(seconds: 5);

  final PodcastApi _api;
  final VoiceRecorder _recorder;
  final AudioOutput _audioOutput;
  final PlaybackPositionStore _positions;
  final Duration pollInterval;
  final Duration searchDebounce;
  late final SourcesController sources;
  late final StreamSubscription<EpisodeProgress> _progressSubscription;

  final List<EpisodeSummary> _episodes = <EpisodeSummary>[];
  final Map<String, EpisodeDetail> _episodeCache = {};
  final Set<String> _transcriptionRequests = <String>{};
  final Set<String> _watchedEpisodes = <String>{};
  final Map<QuestionScope, List<ConversationTurn>> _conversations = {
    QuestionScope.episode: <ConversationTurn>[],
    QuestionScope.library: <ConversationTurn>[],
  };
  Future<void>? _recordingStart;
  Timer? _queryDebounce;
  Timer? _pollTimer;
  List<SourceSummary> _seenSources = const <SourceSummary>[];
  int _listGeneration = 0;
  int _selectionGeneration = 0;
  int _questionGeneration = 0;
  int _playbackGeneration = 0;
  bool _closed = false;

  // Library.
  List<EpisodeSummary> get episodes => List.unmodifiable(_episodes);
  String? nextCursor;
  bool isLoadingEpisodes = false;
  bool isLoadingMore = false;
  String libraryQuery = '';
  String? sourceFilter;
  bool onlyReady = false;

  // Selection and questions.
  EpisodeDetailEnvelope? selectedEpisode;
  bool isSelectingEpisode = false;
  QuestionScope scope = QuestionScope.episode;

  /// The question being answered, or the last one that failed.
  String? pendingQuestion;
  VoiceState voiceState = VoiceState.idle;
  bool isTranscribingVoice = false;
  bool isPreparingSpeech = false;
  bool readAnswersAloud = true;
  AppError? error;
  bool _positionDismissed = false;
  Duration? _capturedPosition;
  bool _resumeAfterQuestion = false;
  int _resumeGeneration = -1;

  // Playback.
  PlayerStatus playerStatus = PlayerStatus.stopped;
  EpisodeDetail? _loadedEpisode;
  Duration _loadedPosition = Duration.zero;
  Duration? _loadedDuration;
  Duration _lastSavedPosition = Duration.zero;
  bool _sawPlaying = false;
  String? activeCitationId;

  /// Position and length of the selected episode, updated while it plays.
  final ValueNotifier<PlaybackProgress> selectedProgress =
      ValueNotifier(const PlaybackProgress());

  String? get errorMessage => error?.message;
  bool get hasMoreEpisodes => nextCursor != null;
  bool get hasLibraryFilter =>
      libraryQuery.isNotEmpty || sourceFilter != null || onlyReady;

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
  bool get canChangeConversation =>
      !_closed && voiceState == VoiceState.idle;
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
  bool get isAudioPlaying =>
      playerStatus == PlayerStatus.playing ||
      playerStatus == PlayerStatus.loading;

  /// The episode in the player, which may differ from the selected one
  /// after playing a citation from another episode.
  EpisodeDetail? get nowPlaying =>
      playerStatus == PlayerStatus.stopped ? null : _loadedEpisode;
  bool get isSelectedLoaded =>
      _loadedEpisode != null &&
      _loadedEpisode!.id == selectedEpisode?.episode.id;
  bool get isPlayingEpisode => isSelectedLoaded && isAudioPlaying;
  bool get isPlayingCitation => activeCitationId != null && isAudioPlaying;
  bool isTranscriptionRequested(String episodeId) =>
      _transcriptionRequests.contains(episodeId);

  List<ConversationTurn> get conversation =>
      List.unmodifiable(_conversations[scope]!);

  /// The newest answer in the current conversation.
  QaResponse? get latestResponse {
    final turns = _conversations[scope]!;
    return turns.isEmpty ? null : turns.last.response;
  }

  /// The question being answered, or else the newest answered question.
  String? get lastQuestionText {
    final turns = _conversations[scope]!;
    return pendingQuestion ?? (turns.isEmpty ? null : turns.last.question);
  }

  /// Position in the selected episode that the next question refers to, or
  /// null when questions are asked without one.
  Duration? get questionPosition {
    if (scope != QuestionScope.episode ||
        _positionDismissed ||
        selectedEpisode == null) {
      return null;
    }
    final position = _capturedPosition ?? selectedProgress.value.position;
    return position >= const Duration(seconds: 1) ? position : null;
  }

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

  void _onSourcesChanged() {
    if (identical(sources.items, _seenSources)) return;
    _seenSources = sources.items;
    _notify();
  }

  void setReadAnswersAloud(bool value) {
    readAnswersAloud = value;
    _notify();
  }

  void dismissError() {
    error = null;
    _notify();
  }

  // Library ------------------------------------------------------------------

  /// Loads the first page of episodes and the podcast list. Selects the
  /// first episode when none is selected yet.
  Future<void> loadInitialEpisodes() async {
    unawaited(sources.load());
    await _reloadEpisodes();
  }

  Future<void> _reloadEpisodes() async {
    if (_closed) return;
    final generation = ++_listGeneration;
    isLoadingEpisodes = true;
    isLoadingMore = false;
    _clearErrors((error) => error.kind == ErrorKind.library);
    _notify();
    try {
      final page = await _api.listEpisodes(
        limit: pageSize,
        sourceId: sourceFilter,
        query: libraryQuery,
        statuses: onlyReady ? {TranscriptionStatus.ready} : null,
      );
      if (_closed || generation != _listGeneration) return;
      _episodes
        ..clear()
        ..addAll(page.items);
      nextCursor = page.nextCursor;
      final selected = selectedEpisode;
      if (selected == null && !isSelectingEpisode) {
        if (_episodes.isNotEmpty) {
          await selectEpisode(_episodes.first.id, notify: false);
        }
      } else if (selected != null) {
        if (_episodes.isEmpty && !hasLibraryFilter && canSelectEpisode) {
          await _clearSelection();
        } else {
          unawaited(_refreshEpisode(selected.episode.id));
        }
      }
    } catch (error) {
      if (generation == _listGeneration) {
        _fail(ErrorKind.library, error,
            'We couldn’t load your episodes. Check your connection and try again.');
      }
    } finally {
      if (generation == _listGeneration) {
        isLoadingEpisodes = false;
        _notify();
      }
    }
  }

  Future<void> loadMoreEpisodes() async {
    if (_closed || isLoadingMore || isLoadingEpisodes || nextCursor == null) {
      return;
    }
    final generation = _listGeneration;
    isLoadingMore = true;
    _notify();
    try {
      final page = await _api.listEpisodes(
        cursor: nextCursor,
        limit: pageSize,
        sourceId: sourceFilter,
        query: libraryQuery,
        statuses: onlyReady ? {TranscriptionStatus.ready} : null,
      );
      if (_closed || generation != _listGeneration) return;
      final known = {for (final episode in _episodes) episode.id};
      _episodes.addAll(page.items.where((item) => !known.contains(item.id)));
      nextCursor = page.nextCursor;
    } catch (error) {
      if (generation == _listGeneration) {
        _fail(ErrorKind.library, error,
            'We couldn’t update your library. Check your connection and try again.');
      }
    } finally {
      if (generation == _listGeneration) {
        isLoadingMore = false;
        _notify();
      }
    }
  }

  /// Searches titles and descriptions on the server once typing pauses.
  void setLibraryQuery(String value) {
    final query = value.trim();
    if (query == libraryQuery) return;
    libraryQuery = query;
    _queryDebounce?.cancel();
    _queryDebounce = Timer(searchDebounce, () => unawaited(_reloadEpisodes()));
  }

  void setSourceFilter(String? sourceId) {
    if (sourceId == sourceFilter) return;
    sourceFilter = sourceId;
    _queryDebounce?.cancel();
    unawaited(_reloadEpisodes());
  }

  void setOnlyReady(bool value) {
    if (value == onlyReady) return;
    onlyReady = value;
    _queryDebounce?.cancel();
    unawaited(_reloadEpisodes());
  }

  Future<void> _clearSelection() async {
    ++_selectionGeneration;
    await stopAudio();
    selectedEpisode = null;
    isSelectingEpisode = false;
    _conversations[QuestionScope.episode]!.clear();
    if (scope == QuestionScope.episode) pendingQuestion = null;
    _setSelectedProgress(const PlaybackProgress());
  }

  Future<void> selectEpisode(String episodeId, {bool notify = true}) async {
    if (!canSelectEpisode) return;
    final generation = ++_selectionGeneration;
    selectedEpisode = null;
    _conversations[QuestionScope.episode]!.clear();
    if (scope == QuestionScope.episode) pendingQuestion = null;
    _positionDismissed = false;
    error = null;
    isSelectingEpisode = true;
    _setSelectedProgress(const PlaybackProgress());
    if (notify) _notify();
    try {
      await stopAudio();
      final envelope = await _api.getEpisode(episodeId);
      if (_closed || generation != _selectionGeneration) return;
      final saved = await _loadSavedPosition(episodeId);
      if (_closed || generation != _selectionGeneration) return;
      selectedEpisode = envelope;
      _episodeCache[episodeId] = envelope.episode;
      _setSelectedProgress(PlaybackProgress(
        position: saved ?? Duration.zero,
        duration: _durationOf(envelope.episode),
      ));
      if (envelope.transcriptionStatus.isInProgress) _watchEpisode(episodeId);
    } catch (error) {
      if (generation == _selectionGeneration) {
        _fail(ErrorKind.episode, error,
            'We couldn’t open that episode. Check your connection and try again.');
      }
    } finally {
      if (generation == _selectionGeneration) {
        isSelectingEpisode = false;
        if (notify) _notify();
      }
    }
  }

  Future<Duration?> _loadSavedPosition(String episodeId) async {
    try {
      return await _positions.load(episodeId);
    } catch (_) {
      // A lost resume position only means starting from the beginning.
      return null;
    }
  }

  Duration? _durationOf(EpisodeSummary episode) {
    final seconds = episode.durationSec;
    return seconds == null || seconds <= 0 ? null : Duration(seconds: seconds);
  }

  // Transcription ------------------------------------------------------------

  /// Asks the server to transcribe [episodeId] and follows it until it is
  /// ready or failed.
  Future<void> requestTranscription(String episodeId) async {
    if (_closed || _transcriptionRequests.contains(episodeId)) return;
    _transcriptionRequests.add(episodeId);
    _clearErrors((error) => error.kind == ErrorKind.transcription);
    _notify();
    try {
      final result = await _api.transcribeEpisode(episodeId);
      if (_closed) return;
      _applySummary(result.episode);
      if (result.episode.transcriptionStatus.isInProgress) {
        _watchEpisode(episodeId);
      }
    } catch (error) {
      if (!_closed) {
        _fail(ErrorKind.transcription, error,
            'We couldn’t start the transcription. Please try again.');
      }
    } finally {
      _transcriptionRequests.remove(episodeId);
      _notify();
    }
  }

  void _watchEpisode(String episodeId) {
    _watchedEpisodes.add(episodeId);
    _schedulePoll();
  }

  void _schedulePoll() {
    if (_closed || _pollTimer != null || _watchedEpisodes.isEmpty) return;
    _pollTimer = Timer(pollInterval, () => unawaited(_pollEpisodes()));
  }

  Future<void> _pollEpisodes() async {
    for (final episodeId in _watchedEpisodes.toList()) {
      if (_closed) return;
      try {
        final envelope = await _api.getEpisode(episodeId);
        if (_closed) return;
        _applyDetail(envelope);
        if (!envelope.transcriptionStatus.isInProgress) {
          _watchedEpisodes.remove(episodeId);
        }
      } on ApiException catch (error) {
        if (error.statusCode == 404) _watchedEpisodes.remove(episodeId);
      } catch (_) {
        // Keep waiting through a brief network problem.
      }
    }
    if (_closed) return;
    _pollTimer = null;
    _notify();
    _schedulePoll();
  }

  Future<void> _refreshEpisode(String episodeId) async {
    try {
      final envelope = await _api.getEpisode(episodeId);
      if (_closed) return;
      _applyDetail(envelope);
      if (envelope.transcriptionStatus.isInProgress) _watchEpisode(episodeId);
      _notify();
    } catch (_) {
      // The list already refreshed; stale details are not worth an error.
    }
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

  // Conversation -------------------------------------------------------------

  void setScope(QuestionScope value) {
    if (value == scope || !canChangeConversation) return;
    scope = value;
    pendingQuestion = null;
    _clearErrors((error) => error.belongsToConversation);
    _notify();
  }

  void startNewConversation() {
    if (!canChangeConversation) return;
    _conversations[scope]!.clear();
    pendingQuestion = null;
    _clearErrors((error) => error.belongsToConversation);
    _notify();
  }

  /// Ask the next question without the playback position.
  void dismissQuestionPosition() {
    if (voiceState != VoiceState.idle) return;
    _positionDismissed = true;
    _notify();
  }

  List<QaTurn> _historyFor(QuestionScope scope) {
    final grounded = _conversations[scope]!
        .where((turn) =>
            turn.response.grounded && turn.response.answerText.isNotEmpty)
        .toList();
    final start =
        grounded.length > historyLimit ? grounded.length - historyLimit : 0;
    return [
      for (final turn in grounded.skip(start))
        QaTurn(question: turn.question, answer: turn.response.answerText),
    ];
  }

  /// Remembers the position and whether to resume once the answer is done.
  void _captureQuestionContext() {
    _capturedPosition = null;
    _capturedPosition = questionPosition;
    _resumeAfterQuestion = isAudioPlaying;
  }

  /// Pauses (does not stop) the episode so the microphone and the spoken
  /// answer do not compete with it.
  Future<void> _pauseForQuestion() async {
    if (!isAudioPlaying) return;
    final position = await _pausePlayer();
    if (_capturedPosition != null && isSelectedLoaded) {
      _capturedPosition = position;
    }
    _resumeGeneration = _playbackGeneration;
  }

  /// Resumes playback that a question paused when nothing else touched the
  /// player meanwhile.
  Future<void> _endQuestion({required bool resume}) async {
    final episode = _loadedEpisode;
    final shouldResume = resume &&
        _resumeAfterQuestion &&
        _resumeGeneration == _playbackGeneration &&
        playerStatus == PlayerStatus.paused &&
        episode != null;
    _resumeAfterQuestion = false;
    _capturedPosition = null;
    if (shouldResume) await _startPlayback(episode, from: _loadedPosition);
  }

  Future<void> startRecording() async {
    if (!canAskQuestion) return;
    _clearErrors((error) => error.belongsToConversation);
    voiceState = VoiceState.starting;
    _captureQuestionContext();
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
      final permission = '$error'.toLowerCase().contains('permission');
      this.error = AppError(
          ErrorKind.recording,
          permission
              ? 'Microphone access is off. Allow it in Settings, or type your question below.'
              : 'The microphone couldn’t start. Try again, or type your question.');
      voiceState = VoiceState.idle;
      await _endQuestion(resume: false);
      _notify();
    } finally {
      if (identical(_recordingStart, start)) _recordingStart = null;
    }
  }

  Future<void> _startRecorder() async {
    await _pauseForQuestion();
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
    isTranscribingVoice = true;
    pendingQuestion = null;
    _notify();
    try {
      await _recordingStart;
      if (_closed) return;
      final audioPath = await _recorder.stop();
      if (audioPath == null || audioPath.isEmpty) throw const _NothingHeard();
      final transcription = await _api.transcribeVoiceFile(audioPath);
      if (_closed) return;
      if (transcription.text.trim().isEmpty) throw const _NothingHeard();
      isTranscribingVoice = false;
      await _answerQuestion(transcription.text.trim());
    } catch (error) {
      if (_closed) return;
      this.error = error is _NothingHeard
          ? const AppError(ErrorKind.recording, _nothingHeardMessage)
          : AppError(ErrorKind.question,
              describeError(error, fallback: _questionFailedMessage));
      isTranscribingVoice = false;
      voiceState = VoiceState.idle;
      await _endQuestion(resume: false);
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
    var resume = true;
    try {
      try {
        await _recordingStart;
      } catch (_) {
        // startRecording already reports permission/startup failures.
        resume = false;
        return;
      }
      if (_closed) return;
      await _recorder.stop();
    } catch (error) {
      this.error = const AppError(ErrorKind.recording,
          'The microphone couldn’t stop cleanly. Please try again.');
    } finally {
      if (!_closed) {
        voiceState = VoiceState.idle;
        if (resume) await _endQuestion(resume: true);
        _notify();
      }
    }
  }

  Future<void> submitTypedQuestion(String questionText) async {
    final trimmed = questionText.trim();
    if (trimmed.isEmpty || !canAskQuestion) return;
    voiceState = VoiceState.processing;
    _clearErrors((error) => error.belongsToConversation);
    _captureQuestionContext();
    pendingQuestion = trimmed;
    _notify();
    await _pauseForQuestion();
    await _answerQuestion(trimmed);
  }

  Future<void> _answerQuestion(String questionText) async {
    final questionScope = scope;
    final episodeId = questionScope == QuestionScope.episode
        ? selectedEpisode?.episode.id
        : null;
    if (_closed) return;
    if (questionScope == QuestionScope.episode && episodeId == null) {
      voiceState = VoiceState.idle;
      await _endQuestion(resume: true);
      _notify();
      return;
    }
    final generation = ++_questionGeneration;
    _clearErrors((error) => error.belongsToConversation);
    pendingQuestion = questionText;
    final position = _capturedPosition;
    final positionSec = questionScope == QuestionScope.episode && position != null
        ? position.inMilliseconds / 1000
        : null;
    _notify();
    var answered = false;
    try {
      final qa = await _api.askQuestion(
        questionText: questionText,
        episodeId: episodeId,
        positionSec: positionSec,
        history: _historyFor(questionScope),
        topK: topK,
      );
      if (_closed || generation != _questionGeneration) return;
      _conversations[questionScope]!.add(ConversationTurn(
          question: questionText, response: qa, positionSec: positionSec));
      pendingQuestion = null;
      answered = true;
      final speak =
          readAnswersAloud && qa.grounded && qa.answerText.trim().isNotEmpty;
      isPreparingSpeech = speak;
      // Render the answer immediately, even if speech generation is slow.
      _notify();
      if (speak) {
        try {
          final synthesized = await _api.synthesize(qa.answerText);
          if (_closed || generation != _questionGeneration) return;
          final bytes = base64Decode(synthesized.audioBase64);
          isPreparingSpeech = false;
          voiceState = VoiceState.speaking;
          _notify();
          await _audioOutput.playTtsBytes(bytes,
              mimeType: synthesized.mimeType);
        } catch (_) {
          if (!_closed && generation == _questionGeneration) {
            error = const AppError(ErrorKind.speech, _speechFailedMessage);
          }
        }
      }
    } catch (error) {
      if (generation == _questionGeneration) {
        _fail(ErrorKind.question, error, _questionFailedMessage);
      }
    } finally {
      if (!_closed && generation == _questionGeneration) {
        isPreparingSpeech = false;
        voiceState = VoiceState.idle;
        // A failed answer leaves playback paused so the message can be read.
        await _endQuestion(resume: answered);
        _notify();
      }
    }
  }

  /// Skips the rest of the spoken answer; paused playback then resumes.
  Future<void> stopSpeech() async {
    if (voiceState != VoiceState.speaking) return;
    try {
      await _audioOutput.stopSpeech();
    } catch (_) {
      // Stopping is best effort; the answer flow ends when speech does.
    }
  }

  // Playback -----------------------------------------------------------------

  Future<void> togglePlayback() =>
      isPlayingEpisode ? pausePlayback() : playSelectedEpisode();

  /// Plays the selected episode from where the listener left off.
  Future<void> playSelectedEpisode() async {
    final episode = selectedEpisode?.episode;
    if (episode == null || !canControlPlayback) return;
    final progress = selectedProgress.value;
    var from = progress.position;
    final duration = progress.duration;
    if (duration != null && from >= duration - finishedMargin) {
      from = Duration.zero;
    }
    await _startPlayback(episode, from: from);
  }

  /// Plays the selected episode from [position], e.g. a chapter start.
  Future<void> playSelectedEpisodeFrom(Duration position) async {
    final episode = selectedEpisode?.episode;
    if (episode == null || !canControlPlayback) return;
    await _startPlayback(episode,
        from: position.isNegative ? Duration.zero : position);
  }

  /// Pauses or resumes the episode in the player, whichever it is.
  Future<void> toggleNowPlaying() async {
    final episode = nowPlaying;
    if (episode == null || !canControlPlayback) return;
    if (isAudioPlaying) {
      await pausePlayback();
    } else {
      await _startPlayback(episode, from: _loadedPosition);
    }
  }

  Future<void> pausePlayback() async {
    if (!isAudioPlaying || !canControlPlayback) return;
    await _pausePlayer();
    _notify();
  }

  Future<Duration> _pausePlayer() async {
    ++_playbackGeneration;
    final wasLoading = playerStatus == PlayerStatus.loading;
    playerStatus = PlayerStatus.paused;
    activeCitationId = null;
    _notify();
    try {
      final position = await _audioOutput.pauseEpisode();
      // While loading, the player has not reached the requested start yet.
      if (!wasLoading) _updateLoadedPosition(position);
    } catch (_) {
      // Keep the last reported position. Should the player keep going, its
      // progress updates switch the status back to playing.
    }
    unawaited(_saveLoadedPosition(force: true));
    return _loadedPosition;
  }

  /// Moves the selected episode to [position]. Without loaded audio this sets
  /// where playback will start.
  Future<void> seekSelectedEpisode(Duration position) async {
    final episode = selectedEpisode?.episode;
    if (episode == null || !canControlPlayback) return;
    final duration = selectedProgress.value.duration;
    var target = position.isNegative ? Duration.zero : position;
    if (duration != null && target > duration) target = duration;
    _positionDismissed = false;
    _setSelectedProgress(PlaybackProgress(position: target, duration: duration));
    if (isSelectedLoaded && playerStatus == PlayerStatus.loading) {
      await _startPlayback(episode, from: target);
      return;
    }
    if (isSelectedLoaded && playerStatus != PlayerStatus.stopped) {
      activeCitationId = null;
      _loadedPosition = target;
      try {
        await _audioOutput.seekEpisode(target);
      } catch (error) {
        _fail(ErrorKind.playback, error, _playbackFailedMessage);
      }
      unawaited(_saveLoadedPosition(force: true));
    } else {
      unawaited(_storePosition(episode.id, target, duration));
    }
    _notify();
  }

  Future<void> playCitation(Citation citation) async {
    if (!canControlPlayback) return;
    final from = Duration(milliseconds: (citation.startSec * 1000).round());
    final known = selectedEpisode?.episode.id == citation.episodeId
        ? selectedEpisode!.episode
        : _episodeCache[citation.episodeId];
    if (known != null) {
      await _startPlayback(known, from: from, citationId: citation.segmentId);
      return;
    }
    final generation = ++_playbackGeneration;
    activeCitationId = citation.segmentId;
    _clearErrors((error) => error.kind == ErrorKind.playback);
    _notify();
    try {
      final envelope = await _api.getEpisode(citation.episodeId);
      if (_closed || generation != _playbackGeneration) return;
      _episodeCache[citation.episodeId] = envelope.episode;
      await _startPlayback(envelope.episode,
          from: from, citationId: citation.segmentId);
    } catch (error) {
      if (!_closed && generation == _playbackGeneration) {
        activeCitationId = null;
        _fail(ErrorKind.playback, error, _playbackFailedMessage);
        _notify();
      }
    }
  }

  Future<void> _startPlayback(EpisodeDetail episode,
      {required Duration from, String? citationId}) async {
    if (_closed) return;
    if (episode.audioUrl.isEmpty) {
      error = const AppError(ErrorKind.playback, _playbackFailedMessage);
      _notify();
      return;
    }
    final generation = ++_playbackGeneration;
    if (voiceState == VoiceState.speaking) {
      // Playing the episode interrupts the spoken answer.
      ++_questionGeneration;
      isPreparingSpeech = false;
      voiceState = VoiceState.idle;
      _resumeAfterQuestion = false;
      _capturedPosition = null;
    }
    final previous = _loadedEpisode;
    if (previous != null && previous.id != episode.id) {
      unawaited(_saveLoadedPosition(force: true));
    }
    _loadedEpisode = episode;
    _loadedPosition = from;
    _loadedDuration = _durationOf(episode);
    _lastSavedPosition = from;
    _sawPlaying = false;
    playerStatus = PlayerStatus.loading;
    activeCitationId = citationId;
    _clearErrors((error) => error.kind == ErrorKind.playback);
    if (episode.id == selectedEpisode?.episode.id) {
      _positionDismissed = false;
      _setSelectedProgress(PlaybackProgress(
          position: from,
          duration: _loadedDuration ?? selectedProgress.value.duration));
    }
    _notify();
    try {
      await _audioOutput.playEpisode(episode.audioUrl, seekTo: from);
      if (_closed || generation != _playbackGeneration) return;
      playerStatus = PlayerStatus.playing;
    } catch (error) {
      if (!_closed && generation == _playbackGeneration) {
        playerStatus = PlayerStatus.paused;
        activeCitationId = null;
        _fail(ErrorKind.playback, error, _playbackFailedMessage);
      }
    } finally {
      if (generation == _playbackGeneration) _notify();
    }
  }

  /// Stops the episode and any spoken answer, remembering the position.
  Future<void> stopAudio() async {
    ++_playbackGeneration;
    if (voiceState == VoiceState.speaking) {
      ++_questionGeneration;
      voiceState = VoiceState.idle;
      isPreparingSpeech = false;
    }
    final saving = _saveLoadedPosition(force: true);
    _loadedEpisode = null;
    playerStatus = PlayerStatus.stopped;
    activeCitationId = null;
    _resumeAfterQuestion = false;
    _capturedPosition = null;
    await Future.wait([_audioOutput.stop(), saving]);
    _notify();
  }

  void _updateLoadedPosition(Duration position) {
    _loadedPosition = position;
    final episode = _loadedEpisode;
    if (episode != null && episode.id == selectedEpisode?.episode.id) {
      _setSelectedProgress(PlaybackProgress(
          position: position,
          duration: _loadedDuration ?? selectedProgress.value.duration));
    }
  }

  void _onProgress(EpisodeProgress progress) {
    final episode = _loadedEpisode;
    if (_closed ||
        episode == null ||
        progress.url != episode.audioUrl ||
        playerStatus == PlayerStatus.loading ||
        playerStatus == PlayerStatus.stopped) {
      return;
    }
    if (progress.completed) {
      _onCompleted(episode);
      return;
    }
    final duration = progress.duration;
    if (duration != null && duration > Duration.zero) {
      _loadedDuration = duration;
    }
    _updateLoadedPosition(progress.position);
    // Follow pauses and resumes that did not come from the app, such as an
    // audio interruption. Ignore stale updates from before playback began.
    if (progress.playing) {
      _sawPlaying = true;
      if (playerStatus == PlayerStatus.paused) {
        playerStatus = PlayerStatus.playing;
        _notify();
      }
    } else if (playerStatus == PlayerStatus.playing && _sawPlaying) {
      playerStatus = PlayerStatus.paused;
      activeCitationId = null;
      unawaited(_saveLoadedPosition(force: true));
      _notify();
      return;
    }
    if (playerStatus == PlayerStatus.playing) unawaited(_saveLoadedPosition());
  }

  void _onCompleted(EpisodeDetail episode) {
    ++_playbackGeneration;
    playerStatus = PlayerStatus.stopped;
    activeCitationId = null;
    _loadedPosition = Duration.zero;
    _lastSavedPosition = Duration.zero;
    unawaited(_clearPosition(episode.id));
    if (episode.id == selectedEpisode?.episode.id) {
      _setSelectedProgress(PlaybackProgress(
          duration: _loadedDuration ?? selectedProgress.value.duration));
    }
    _notify();
  }

  void _onPlaybackError(Object error) {
    if (_closed || playerStatus != PlayerStatus.playing) return;
    ++_playbackGeneration;
    playerStatus = PlayerStatus.paused;
    activeCitationId = null;
    _fail(ErrorKind.playback, error, _playbackFailedMessage);
    unawaited(_saveLoadedPosition(force: true));
    _notify();
  }

  /// Saves the position of the episode in the player, e.g. when the app
  /// moves to the background.
  Future<void> savePlaybackPosition() => _saveLoadedPosition(force: true);

  Future<void> _saveLoadedPosition({bool force = false}) async {
    final episode = _loadedEpisode;
    if (episode == null || playerStatus == PlayerStatus.loading) return;
    final position = _loadedPosition;
    if (!force && (position - _lastSavedPosition).abs() < _saveEvery) return;
    _lastSavedPosition = position;
    await _storePosition(
        episode.id, position, _loadedDuration ?? _durationOf(episode));
  }

  Future<void> _storePosition(
      String episodeId, Duration position, Duration? duration) async {
    final finished = duration != null &&
        duration > finishedMargin &&
        position >= duration - finishedMargin;
    if (position < const Duration(seconds: 1) || finished) {
      await _clearPosition(episodeId);
      return;
    }
    try {
      await _positions.save(episodeId, position);
    } catch (_) {
      // Losing a resume position is not worth interrupting playback.
    }
  }

  Future<void> _clearPosition(String episodeId) async {
    try {
      await _positions.clear(episodeId);
    } catch (_) {
      // See _storePosition.
    }
  }

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
    await _progressSubscription.cancel();
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
    sources
      ..removeListener(_onSourcesChanged)
      ..dispose();
    selectedProgress.dispose();
    super.dispose();
  }
}
