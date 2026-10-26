import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:podcast_voice_ai/audio_output.dart';
import 'package:podcast_voice_ai/models.dart';
import 'package:podcast_voice_ai/podcast_api.dart';
import 'package:podcast_voice_ai/voice_recorder.dart';

/// What the fakes play for an episode: never its publisher [audioUrl].
String playbackUrlOf(String episodeId) => 'https://media.example/$episodeId.mp3';

EpisodeSummary demoEpisode(
  String id, {
  String? title,
  TranscriptionStatus status = TranscriptionStatus.ready,
  String sourceId = 'src1',
  String sourceName = 'Demo',
  String? transcriptionError,
  String? imageUrl,
  int durationSec = 900,
}) =>
    EpisodeSummary(
      id: id,
      sourceId: sourceId,
      sourceName: sourceName,
      title: title ?? 'Episode $id',
      description: 'About $id',
      publishedAt: DateTime.parse('2025-01-01T00:00:00Z'),
      audioUrl: 'https://example.com/$id.mp3',
      playbackUrl: playbackUrlOf(id),
      transcriptionStatus: status,
      transcriptionError: transcriptionError,
      imageUrl: imageUrl,
      durationSec: durationSec,
    );

SourceSummary demoSource(
  String id,
  String name, {
  IngestJobStatus? job = IngestJobStatus.completed,
  String? jobError,
  int episodes = 12,
  int ready = 1,
  String? rssUrl,
  bool autoTranscribe = false,
  DateTime? lastRefreshedAt,
}) =>
    SourceSummary(
      id: id,
      name: name,
      rssUrl: rssUrl ?? 'https://feeds.example/$id.xml',
      episodeCount: episodes,
      readyEpisodeCount: ready,
      lastJob: job == null ? null : IngestJob(status: job, error: jobError),
      autoTranscribe: autoTranscribe,
      lastRefreshedAt: lastRefreshedAt,
    );

typedef AddRequest = ({String rssUrl, String? name, String? imageUrl});

class FakeApi implements PodcastApi {
  /// The library; listed [pageSize] at a time.
  List<EpisodeSummary> library = [
    demoEpisode('ep1', title: 'Episode 1'),
    demoEpisode('ep2', title: 'Episode 2'),
  ];
  int pageSize = 1;
  int listCalls = 0;
  bool throwOnList = false;
  bool emptyLibrary = false;
  String? lastListQuery;
  String? lastListSourceId;
  Set<TranscriptionStatus>? lastListStatuses;

  final Map<String, Completer<void>> episodeGates = {};
  final Map<String, int> episodeCalls = {};

  /// Statuses returned by successive getEpisode calls; the last one sticks.
  final Map<String, List<TranscriptionStatus>> statusSequence = {};

  /// Playback links returned by successive getEpisode calls; the last one
  /// sticks. Defaults to [playbackUrlOf].
  final Map<String, List<String>> playbackUrlSequence = {};
  final Map<String, EpisodeDetail> details = {};

  int transcribeCalls = 0;
  Object? transcribeError;

  TranscriptionUsage? usage = TranscriptionUsage(
      date: '2026-10-26',
      usedMinutes: 60,
      limitMinutes: 180,
      remainingMinutes: 120);
  int usageCalls = 0;
  Object? usageError;

  final List<({String sourceId, bool autoTranscribe})> sourceUpdates = [];
  Object? updateSourceError;
  Completer<void>? updateSourceGate;

  List<SourceSummary> sources = [demoSource('src1', 'Demo')];

  /// Responses for successive listSources calls; the last one sticks.
  final List<List<SourceSummary>> sourceSnapshots = [];
  int sourcesCalls = 0;
  List<PodcastSearchResult> searchResults = [];
  final List<String> searchQueries = [];
  final List<AddRequest> addRequests = [];
  Object? addError;

  bool refuseAnswer = false;
  bool failSynthesis = false;
  bool failQuestion = false;
  int questionCalls = 0;
  int transcriptionCalls = 0;
  int synthesisCalls = 0;
  bool askedWithEpisode = false;
  String? lastQuestionEpisode;
  String? lastQuestionText;
  double? lastPositionSec;
  List<QaTurn> lastHistory = const [];
  int? lastTopK;
  String? citationEpisodeId;
  double? citationPlayFromSec;
  Completer<void>? questionGate;
  Completer<void>? transcriptionGate;

  /// The episode a voice question was transcribed for.
  String? lastVoiceEpisodeId;

  /// Holds the stream after its status events, before any answer text.
  Completer<void>? beforeDeltas;

  /// Holds the stream after the answer text, before the final answer.
  Completer<void>? beforeDone;

  /// Ends the stream with an `error` event after some text.
  String? streamError;

  /// Streams answer text, then a refusal as the final answer.
  bool refuseAfterDeltas = false;

  /// Ends the stream without a final answer.
  bool truncateStream = false;

  @override
  Future<EpisodePage> listEpisodes({
    String? cursor,
    int limit = 20,
    String? sourceId,
    String? query,
    Set<TranscriptionStatus>? statuses,
  }) async {
    if (throwOnList) throw Exception('network failure');
    listCalls += 1;
    lastListQuery = query;
    lastListSourceId = sourceId;
    lastListStatuses = statuses;
    if (emptyLibrary) return EpisodePage(items: [], nextCursor: null);
    final text = query?.toLowerCase() ?? '';
    final matches = library
        .where((episode) =>
            (sourceId == null || episode.sourceId == sourceId) &&
            (statuses == null ||
                statuses.contains(episode.transcriptionStatus)) &&
            '${episode.title} ${episode.description}'
                .toLowerCase()
                .contains(text))
        .toList();
    final start = cursor == null ? 0 : int.parse(cursor.split('-').last);
    final end = (start + pageSize).clamp(0, matches.length);
    return EpisodePage(
      items: matches.sublist(start.clamp(0, matches.length), end),
      nextCursor: end < matches.length ? 'cursor-$end' : null,
    );
  }

  TranscriptionStatus _statusOf(String episodeId) {
    final sequence = statusSequence[episodeId];
    if (sequence != null && sequence.isNotEmpty) {
      return sequence.length > 1 ? sequence.removeAt(0) : sequence.first;
    }
    if (episodeId == 'pending') return TranscriptionStatus.pending;
    for (final episode in library) {
      if (episode.id == episodeId) return episode.transcriptionStatus;
    }
    return TranscriptionStatus.ready;
  }

  String _playbackUrlOf(String episodeId) {
    final sequence = playbackUrlSequence[episodeId];
    if (sequence != null && sequence.isNotEmpty) {
      return sequence.length > 1 ? sequence.removeAt(0) : sequence.first;
    }
    return playbackUrlOf(episodeId);
  }

  @override
  Future<EpisodeDetailEnvelope> getEpisode(String episodeId) async {
    episodeCalls[episodeId] = (episodeCalls[episodeId] ?? 0) + 1;
    await episodeGates[episodeId]?.future;
    final status = _statusOf(episodeId);
    final override = details[episodeId];
    if (override != null) {
      return EpisodeDetailEnvelope(
          episode: override.copyWithStatus(status,
              transcriptionError: override.transcriptionError),
          transcriptionStatus: status);
    }
    final playbackUrl = _playbackUrlOf(episodeId);
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
        playbackUrl: playbackUrl,
        transcriptionStatus: status,
        durationSec: 900,
      ),
      transcriptionStatus: status,
    );
  }

  @override
  Future<TranscriptionUsage> getUsage() async {
    usageCalls += 1;
    final error = usageError;
    if (error != null) throw error;
    final current = usage;
    if (current == null) throw Exception('usage unavailable');
    return current;
  }

  @override
  Future<SourceSummary> updateSource(String sourceId,
      {required bool autoTranscribe}) async {
    sourceUpdates.add((sourceId: sourceId, autoTranscribe: autoTranscribe));
    await updateSourceGate?.future;
    final error = updateSourceError;
    if (error != null) throw error;
    final index = sources.indexWhere((source) => source.id == sourceId);
    if (index < 0) throw ApiException(statusCode: 404);
    final updated = sources[index].copyWith(autoTranscribe: autoTranscribe);
    sources = [...sources]..[index] = updated;
    return updated;
  }

  @override
  Future<TranscribeEpisodeResult> transcribeEpisode(String episodeId) async {
    transcribeCalls += 1;
    final error = transcribeError;
    if (error != null) throw error;
    final index = library.indexWhere((episode) => episode.id == episodeId);
    final current = index >= 0 ? library[index] : demoEpisode(episodeId);
    final queued = current.copyWithStatus(TranscriptionStatus.queued);
    if (index >= 0) library[index] = queued;
    return TranscribeEpisodeResult(jobId: 'job-$episodeId', episode: queued);
  }

  @override
  Future<List<PodcastSearchResult>> searchPodcasts(String query) async {
    searchQueries.add(query);
    return searchResults
        .where((result) =>
            result.title.toLowerCase().contains(query.toLowerCase()))
        .toList();
  }

  @override
  Future<List<SourceSummary>> listSources() async {
    sourcesCalls += 1;
    if (sourceSnapshots.isNotEmpty) {
      sources = sourceSnapshots.length > 1
          ? sourceSnapshots.removeAt(0)
          : sourceSnapshots.first;
    }
    return List.of(sources);
  }

  @override
  Future<SourceSummary> addSource({
    required String rssUrl,
    String? name,
    String? imageUrl,
  }) async {
    addRequests.add((rssUrl: rssUrl, name: name, imageUrl: imageUrl));
    final error = addError;
    if (error != null) throw error;
    final source = SourceSummary(
      id: 'src-new',
      name: name ?? 'New podcast',
      rssUrl: rssUrl,
      imageUrl: imageUrl,
      lastJob: IngestJob(status: IngestJobStatus.queued),
    );
    sources = [...sources, source];
    return source;
  }

  @override
  Future<TranscriptionResult> transcribeVoiceFile(String audioPath,
      {String? episodeId}) async {
    transcriptionCalls += 1;
    lastVoiceEpisodeId = episodeId;
    await transcriptionGate?.future;
    return TranscriptionResult(text: 'What was discussed?', durationMs: 1500);
  }

  QaResponse get refusal => QaResponse(
        answerText:
            'I do not have enough transcript evidence to answer that confidently.',
        citations: const <Citation>[],
        grounded: false,
        refusalReason: 'insufficient_retrieval_confidence',
      );

  QaResponse groundedAnswer(String? episodeId) {
    final cited = citationEpisodeId ?? episodeId ?? 'ep2';
    return QaResponse(
      answerText: 'The host discussed architecture and citations.',
      citations: [
        Citation(
          segmentId: 'seg1',
          episodeId: cited,
          episodeTitle: 'Episode $cited',
          startSec: 120,
          endSec: 140,
          playFromSec: citationPlayFromSec,
          text: 'Architecture and citations were discussed.',
          score: 0.88,
        ),
      ],
      grounded: true,
    );
  }

  @override
  Stream<QaStreamEvent> askQuestionStream({
    required String questionText,
    String? episodeId,
    double? positionSec,
    List<QaTurn> history = const <QaTurn>[],
    int topK = 10,
  }) async* {
    questionCalls += 1;
    askedWithEpisode = episodeId != null;
    lastQuestionEpisode = episodeId;
    lastQuestionText = questionText;
    lastPositionSec = positionSec;
    lastHistory = List.of(history);
    lastTopK = topK;
    await questionGate?.future;
    if (failQuestion) throw Exception('question unavailable');
    yield const QaStatusEvent(AnswerStage.searching);
    yield const QaStatusEvent(AnswerStage.answering);
    await beforeDeltas?.future;
    final answer = refuseAnswer ? refusal : groundedAnswer(episodeId);
    final error = streamError;
    if (error != null) {
      yield const QaDeltaEvent('The host ');
      yield QaErrorEvent(error, requestId: 'req-stream');
      return;
    }
    if (!refuseAnswer || refuseAfterDeltas) {
      yield const QaDeltaEvent('The host discussed ');
      yield const QaDeltaEvent('architecture');
    }
    await beforeDone?.future;
    if (truncateStream) return;
    yield QaDoneEvent(refuseAfterDeltas ? refusal : answer);
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
  Future<void> dispose() async {}
}

class FakeAudioOutput implements AudioOutput {
  final StreamController<EpisodeProgress> _progress =
      StreamController<EpisodeProgress>.broadcast(sync: true);
  final StreamController<RemoteCommand> _remote =
      StreamController<RemoteCommand>.broadcast(sync: true);

  /// What playEpisode was asked to show on the lock screen.
  EpisodeMedia? lastMedia;

  /// Links that fail to load, like an expired signed link.
  final Set<String> failingUrls = {};

  /// Calls in order, e.g. `play https://example.com/ep1.mp3@0`, `pause`.
  final List<String> events = [];
  Duration? lastSeek;
  String? lastEpisodeUrl;
  Duration position = Duration.zero;
  int playCalls = 0;
  int pauseCalls = 0;
  int seekCalls = 0;
  int ttsCalls = 0;
  int stopCalls = 0;
  int stopSpeechCalls = 0;
  String? lastMimeType;
  bool failEpisodePlayback = false;
  bool failPause = false;
  bool blockTts = false;
  Completer<void>? ttsGate;

  /// Holds playEpisode before playback starts.
  Completer<void>? startGate;
  Completer<void>? stopGate;

  @override
  Stream<EpisodeProgress> get episodeProgress => _progress.stream;

  @override
  Stream<RemoteCommand> get remoteCommands => _remote.stream;

  /// A command from the lock screen, notification or headset.
  void remote(RemoteCommand command) => _remote.add(command);

  /// Reports player progress for the loaded episode.
  void emit(Duration at,
      {bool playing = true, bool completed = false, Duration? duration}) {
    position = at;
    _progress.add(EpisodeProgress(
      url: lastEpisodeUrl!,
      position: at,
      duration: duration,
      playing: playing,
      completed: completed,
    ));
  }

  void emitError(Object error) => _progress.addError(error);

  void _endSpeech() {
    final gate = ttsGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> playEpisode(String url,
      {Duration? seekTo, EpisodeMedia? media}) async {
    playCalls += 1;
    events.add('play $url@${seekTo?.inMilliseconds}');
    lastMedia = media;
    _endSpeech();
    if (failEpisodePlayback || failingUrls.contains(url)) {
      throw Exception('audio unavailable');
    }
    lastEpisodeUrl = url;
    lastSeek = seekTo;
    if (seekTo != null) position = seekTo;
    await startGate?.future;
  }

  @override
  Future<Duration> pauseEpisode() async {
    pauseCalls += 1;
    events.add('pause');
    if (failPause) throw Exception('pause failed');
    return position;
  }

  @override
  Future<void> seekEpisode(Duration to) async {
    seekCalls += 1;
    events.add('seek ${to.inMilliseconds}');
    lastSeek = to;
    position = to;
  }

  @override
  Future<void> playTtsBytes(Uint8List audioBytes,
      {String mimeType = 'audio/mpeg'}) async {
    ttsCalls += 1;
    events.add('tts');
    lastMimeType = mimeType;
    if (blockTts) ttsGate = Completer<void>();
    await ttsGate?.future;
  }

  @override
  Future<void> stopSpeech() async {
    stopSpeechCalls += 1;
    events.add('stopSpeech');
    _endSpeech();
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    events.add('stop');
    _endSpeech();
    await stopGate?.future;
  }

  @override
  Future<void> dispose() async {
    await _progress.close();
    await _remote.close();
  }
}

class FakeAuthApi implements AuthApi {
  static const password = 'correct horse battery';
  User user =
      const User(id: 'u1', email: 'ada@example.com', name: 'Ada Lovelace');
  int loginCalls = 0;
  int meCalls = 0;
  int _tokens = 0;
  final List<String> loggedOut = [];
  Object? loginError;
  Object? meError;
  Completer<void>? loginGate;
  DateTime expiresAt = DateTime.utc(2099);

  @override
  Future<LoginResult> login(
      {required String email, required String password}) async {
    loginCalls += 1;
    await loginGate?.future;
    final error = loginError;
    if (error != null) throw error;
    if (email != user.email || password != FakeAuthApi.password) {
      throw ApiException(
          statusCode: 401, serverMessage: 'invalid email or password');
    }
    return LoginResult(
        token: 'token-${++_tokens}', user: user, expiresAt: expiresAt);
  }

  @override
  Future<void> logout(String token) async => loggedOut.add(token);

  @override
  Future<User> me() async {
    meCalls += 1;
    final error = meError;
    if (error != null) throw error;
    return user;
  }
}
