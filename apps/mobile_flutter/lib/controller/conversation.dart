part of '../podcast_controller.dart';

class _NothingHeard implements Exception {
  const _NothingHeard();
}

const _nothingHeardMessage =
    'I didn’t catch that. Try speaking again, or type your question.';
const _questionFailedMessage =
    'Something interrupted that request. Please try again. You can also type your question.';
const _speechFailedMessage =
    'Your answer is ready to read. Spoken playback is unavailable right now.';

/// Questions (typed or recorded), streamed answers, spoken answers and the
/// conversation of each scope, which is kept across restarts.
mixin _Conversation on _ControllerCore, _Playback {
  final Map<QuestionScope, List<ConversationTurn>> _conversations = {
    QuestionScope.episode: <ConversationTurn>[],
    QuestionScope.library: <ConversationTurn>[],
  };
  Future<void>? _recordingStart;
  int _resumeGeneration = -1;

  /// Completes once the stored library conversation has been restored.
  Future<void> _libraryRestored = Future<void>.value();

  /// Changes when the library conversation is cleared, so a slow restore
  /// does not bring back what the listener just cleared.
  int _libraryConversationVersion = 0;

  /// The question being answered, or the last one that failed.
  String? pendingQuestion;
  bool isTranscribingVoice = false;
  bool readAnswersAloud = true;

  /// What the server is doing for the question being answered; null when no
  /// answer is being streamed.
  AnswerStage? answerStage;

  /// The answer text streamed so far. The final answer replaces it.
  final ValueNotifier<String> streamingAnswer = ValueNotifier('');

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

  void setReadAnswersAloud(bool value) {
    readAnswersAloud = value;
    _notify();
  }

  void setScope(QuestionScope value) {
    if (value == scope || !canChangeConversation) return;
    scope = value;
    pendingQuestion = null;
    _clearErrors((error) => error.belongsToConversation);
    _notify();
  }

  /// Clears the current conversation, also on the device.
  void startNewConversation() {
    if (!canChangeConversation) return;
    _conversations[scope]!.clear();
    final key = _storageKey(scope, selectedEpisode?.episode.id);
    if (scope == QuestionScope.library) ++_libraryConversationVersion;
    if (key != null) unawaited(_forgetConversation(key));
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

  // Stored conversations ------------------------------------------------------

  String? _storageKey(QuestionScope scope, String? episodeId) =>
      scope == QuestionScope.library
          ? libraryConversationKey()
          : episodeId == null
              ? null
              : episodeConversationKey(episodeId);

  Future<List<ConversationTurn>> _loadStoredTurns(String key) async {
    try {
      return await _conversationStore.load(key);
    } catch (_) {
      // An unreadable conversation only means starting a new one.
      return const <ConversationTurn>[];
    }
  }

  /// The stored conversation about [episodeId], to restore on selection.
  Future<List<ConversationTurn>> _loadEpisodeConversation(String episodeId) =>
      _loadStoredTurns(episodeConversationKey(episodeId));

  Future<void> _restoreLibraryConversation() async {
    final version = _libraryConversationVersion;
    final stored = await _loadStoredTurns(libraryConversationKey());
    if (_closed || stored.isEmpty || version != _libraryConversationVersion) {
      return;
    }
    // Questions asked while restoring come after the restored ones.
    _conversations[QuestionScope.library]!.insertAll(0, stored);
    _notify();
  }

  Future<void> _storeConversation(
      QuestionScope scope, String? episodeId) async {
    final key = _storageKey(scope, episodeId);
    if (key == null) return;
    List<ConversationTurn> turns;
    if (scope == QuestionScope.library) {
      await _libraryRestored;
      if (_closed) return;
      turns = List.of(_conversations[QuestionScope.library]!);
    } else {
      turns = List.of(_conversations[QuestionScope.episode]!);
    }
    try {
      await _conversationStore.save(key, turns);
    } catch (_) {
      // The conversation stays on screen; it just won't survive a restart.
    }
  }

  Future<void> _forgetConversation(String key) async {
    try {
      await _conversationStore.clear(key);
    } catch (_) {
      // See _storeConversation.
    }
  }

  // Asking -------------------------------------------------------------------

  List<QaTurn> _historyFor(QuestionScope scope) {
    final grounded = _conversations[scope]!
        .where((turn) =>
            turn.response.grounded && turn.response.answerText.isNotEmpty)
        .toList();
    final start = grounded.length > PodcastController.historyLimit
        ? grounded.length - PodcastController.historyLimit
        : 0;
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
      // Names from the episode help the server spell what was asked.
      final transcription = await _api.transcribeVoiceFile(audioPath,
          episodeId: scope == QuestionScope.episode
              ? selectedEpisode?.episode.id
              : null);
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

  void _setStreamingAnswer(String text) {
    if (!_closed) streamingAnswer.value = text;
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
    final positionSec =
        questionScope == QuestionScope.episode && position != null
            ? position.inMilliseconds / 1000
            : null;
    answerStage = AnswerStage.searching;
    _setStreamingAnswer('');
    _notify();
    var answered = false;
    try {
      final qa = await _streamAnswer(
        generation,
        questionText: questionText,
        episodeId: episodeId,
        positionSec: positionSec,
        history: _historyFor(questionScope),
      );
      if (qa == null || _closed || generation != _questionGeneration) return;
      // The final answer replaces the streamed text; it may be a refusal.
      answerStage = null;
      _setStreamingAnswer('');
      _conversations[questionScope]!.add(ConversationTurn(
          question: questionText, response: qa, positionSec: positionSec));
      unawaited(_storeConversation(questionScope, episodeId));
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
        answerStage = null;
        _setStreamingAnswer('');
        isPreparingSpeech = false;
        voiceState = VoiceState.idle;
        // A failed answer leaves playback paused so the message can be read.
        await _endQuestion(resume: answered);
        _notify();
      }
    }
  }

  /// Follows the answer stream for question [generation]. Returns the final
  /// answer, or null once a newer question or closing took over (which also
  /// cancels the request).
  Future<QaResponse?> _streamAnswer(
    int generation, {
    required String questionText,
    required String? episodeId,
    required double? positionSec,
    required List<QaTurn> history,
  }) async {
    final events = _api.askQuestionStream(
      questionText: questionText,
      episodeId: episodeId,
      positionSec: positionSec,
      history: history,
      topK: PodcastController.topK,
    );
    await for (final event in events) {
      if (_closed || generation != _questionGeneration) return null;
      switch (event) {
        case QaStatusEvent(:final stage):
          if (answerStage != stage) {
            answerStage = stage;
            _notify();
          }
        case QaDeltaEvent(:final text):
          if (answerStage != AnswerStage.answering) {
            answerStage = AnswerStage.answering;
            _notify();
          }
          _setStreamingAnswer(streamingAnswer.value + text);
        case QaDoneEvent(:final response):
          return response;
        case QaErrorEvent(:final error, :final requestId):
          throw AnswerStreamException(
              serverMessage: error, requestId: requestId);
      }
    }
    if (_closed || generation != _questionGeneration) return null;
    // The connection ended before the final answer.
    throw const AnswerStreamException();
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
}
