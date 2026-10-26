// Client models for the HTTP API. The JSON shapes are defined in
// packages/shared-types/src/index.ts. Parsing is defensive: a missing or
// unexpected optional field falls back to a neutral value instead of throwing.

/// pending: listed from the feed, transcription not requested.
/// queued: transcription requested, waiting for the worker.
/// processing: the worker is downloading, transcribing or indexing it.
enum TranscriptionStatus { pending, queued, processing, ready, failed }

extension TranscriptionStatusInfo on TranscriptionStatus {
  bool get isInProgress =>
      this == TranscriptionStatus.queued ||
      this == TranscriptionStatus.processing;

  /// Whether the user can ask the server to transcribe the episode.
  bool get canRequestTranscription =>
      this == TranscriptionStatus.pending || this == TranscriptionStatus.failed;
}

TranscriptionStatus transcriptionStatusFromString(Object? value) =>
    switch (value) {
      'queued' => TranscriptionStatus.queued,
      'processing' => TranscriptionStatus.processing,
      'ready' => TranscriptionStatus.ready,
      'failed' => TranscriptionStatus.failed,
      _ => TranscriptionStatus.pending,
    };

enum IngestJobStatus { queued, processing, completed, failed, unknown }

extension IngestJobStatusInfo on IngestJobStatus {
  bool get isInProgress =>
      this == IngestJobStatus.queued || this == IngestJobStatus.processing;
}

IngestJobStatus ingestJobStatusFromString(Object? value) => switch (value) {
      'queued' => IngestJobStatus.queued,
      'processing' => IngestJobStatus.processing,
      'completed' => IngestJobStatus.completed,
      'failed' => IngestJobStatus.failed,
      _ => IngestJobStatus.unknown,
    };

enum CitationKind { segment, chapter }

String _string(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

double? _optionalDouble(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

double _double(Object? value) => _optionalDouble(value) ?? 0;

int? _optionalInt(Object? value) =>
    value is num && value.isFinite ? value.round() : null;

Map<String, dynamic>? _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : null;

/// Parses each map in [value] and skips entries that are not objects or that
/// [parse] rejects by returning null.
List<T> _list<T extends Object>(
    Object? value, T? Function(Map<String, dynamic> json) parse) {
  if (value is! List) return <T>[];
  return value
      .map(_map)
      .whereType<Map<String, dynamic>>()
      .map(parse)
      .whereType<T>()
      .toList();
}

DateTime _date(Object? value) =>
    DateTime.tryParse(_string(value)) ?? DateTime.now();

DateTime? _optionalDate(Object? value) => DateTime.tryParse(_string(value));

class EpisodeSummary {
  EpisodeSummary({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.title,
    required this.description,
    required this.publishedAt,
    required this.audioUrl,
    required this.transcriptionStatus,
    this.imageUrl,
    this.durationSec,
    this.transcriptionError,
  });

  final String id;
  final String sourceId;
  final String sourceName;
  final String title;
  final String description;
  final DateTime publishedAt;
  final String audioUrl;
  final TranscriptionStatus transcriptionStatus;
  final String? imageUrl;
  final int? durationSec;

  /// Last failure reason; null unless the latest attempt failed.
  final String? transcriptionError;

  /// Returns null when [json] has no episode id.
  static EpisodeSummary? tryParse(Map<String, dynamic> json) =>
      _string(json['id']).isEmpty ? null : EpisodeSummary.fromJson(json);

  factory EpisodeSummary.fromJson(Map<String, dynamic> json) {
    return EpisodeSummary(
      id: _string(json['id']),
      sourceId: _string(json['sourceId']),
      sourceName: _string(json['sourceName']),
      title: _string(json['title'], 'Untitled'),
      description: _string(json['description']),
      publishedAt: _date(json['publishedAt']),
      audioUrl: _string(json['audioUrl']),
      transcriptionStatus:
          transcriptionStatusFromString(json['transcriptionStatus']),
      imageUrl: _optionalString(json['imageUrl']),
      durationSec: _optionalInt(json['durationSec']),
      transcriptionError: _optionalString(json['transcriptionError']),
    );
  }

  EpisodeSummary copyWithStatus(
    TranscriptionStatus status, {
    String? transcriptionError,
  }) =>
      EpisodeSummary(
        id: id,
        sourceId: sourceId,
        sourceName: sourceName,
        title: title,
        description: description,
        publishedAt: publishedAt,
        audioUrl: audioUrl,
        transcriptionStatus: status,
        imageUrl: imageUrl,
        durationSec: durationSec,
        transcriptionError: transcriptionError,
      );
}

class Chapter {
  Chapter({
    required this.id,
    required this.title,
    required this.summary,
    required this.startSec,
    required this.endSec,
  });

  final String id;
  final String title;
  final String summary;
  final double startSec;
  final double endSec;

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        id: _string(json['id']),
        title: _string(json['title'], 'Chapter'),
        summary: _string(json['summary']),
        startSec: _double(json['startSec']),
        endSec: _double(json['endSec']),
      );
}

class EpisodeDetail extends EpisodeSummary {
  EpisodeDetail({
    required super.id,
    required super.sourceId,
    required super.sourceName,
    required this.guid,
    required super.title,
    required super.description,
    required super.publishedAt,
    required super.audioUrl,
    required super.transcriptionStatus,
    super.durationSec,
    super.imageUrl,
    super.transcriptionError,
    this.language,
    this.summary,
    this.chapters = const <Chapter>[],
  });

  final String guid;

  /// BCP 47 code of the spoken language, when known.
  final String? language;
  final String? summary;

  /// Ordered by start time.
  final List<Chapter> chapters;

  factory EpisodeDetail.fromJson(Map<String, dynamic> json) {
    final chapters = _list(json['chapters'], Chapter.fromJson)
      ..sort((a, b) => a.startSec.compareTo(b.startSec));
    return EpisodeDetail(
      id: _string(json['id']),
      sourceId: _string(json['sourceId']),
      sourceName: _string(json['sourceName']),
      guid: _string(json['guid']),
      title: _string(json['title'], 'Untitled'),
      description: _string(json['description']),
      publishedAt: _date(json['publishedAt']),
      audioUrl: _string(json['audioUrl']),
      transcriptionStatus:
          transcriptionStatusFromString(json['transcriptionStatus']),
      durationSec: _optionalInt(json['durationSec']),
      imageUrl: _optionalString(json['imageUrl']),
      transcriptionError: _optionalString(json['transcriptionError']),
      language: _optionalString(json['language']),
      summary: _optionalString(json['summary']),
      chapters: List.unmodifiable(chapters),
    );
  }

  @override
  EpisodeDetail copyWithStatus(
    TranscriptionStatus status, {
    String? transcriptionError,
  }) =>
      EpisodeDetail(
        id: id,
        sourceId: sourceId,
        sourceName: sourceName,
        guid: guid,
        title: title,
        description: description,
        publishedAt: publishedAt,
        audioUrl: audioUrl,
        transcriptionStatus: status,
        durationSec: durationSec,
        imageUrl: imageUrl,
        transcriptionError: transcriptionError,
        language: language,
        summary: summary,
        chapters: chapters,
      );
}

class EpisodeDetailEnvelope {
  EpisodeDetailEnvelope(
      {required this.episode, required this.transcriptionStatus});

  final EpisodeDetail episode;
  final TranscriptionStatus transcriptionStatus;

  factory EpisodeDetailEnvelope.fromJson(Map<String, dynamic> json) {
    final episode = _map(json['episode']);
    if (episode == null || _string(episode['id']).isEmpty) {
      throw const FormatException('Episode response has no episode.');
    }
    final detail = EpisodeDetail.fromJson(episode);
    return EpisodeDetailEnvelope(
      episode: detail,
      transcriptionStatus: json.containsKey('transcriptionStatus')
          ? transcriptionStatusFromString(json['transcriptionStatus'])
          : detail.transcriptionStatus,
    );
  }
}

class Citation {
  Citation({
    required this.segmentId,
    required this.episodeId,
    required this.episodeTitle,
    required this.startSec,
    required this.endSec,
    required this.text,
    required this.score,
    this.kind = CitationKind.segment,
  });

  /// Transcript segment id, or `chapter:<id>` for a chapter citation.
  final String segmentId;
  final CitationKind kind;
  final String episodeId;
  final String episodeTitle;
  final double startSec;
  final double endSec;
  final String text;
  final double score;

  /// Returns null when [json] does not name the cited episode.
  static Citation? tryParse(Map<String, dynamic> json) =>
      _string(json['episodeId']).isEmpty ? null : Citation.fromJson(json);

  factory Citation.fromJson(Map<String, dynamic> json) {
    return Citation(
      segmentId: _string(json['segmentId']),
      kind: json['kind'] == 'chapter'
          ? CitationKind.chapter
          : CitationKind.segment,
      episodeId: _string(json['episodeId']),
      episodeTitle: _string(json['episodeTitle']),
      startSec: _double(json['startSec']),
      endSec: _double(json['endSec']),
      text: _string(json['text']),
      score: _double(json['score']),
    );
  }
}

/// One earlier exchange, sent as `history` with follow-up questions.
class QaTurn {
  const QaTurn({required this.question, required this.answer});

  final String question;
  final String answer;

  Map<String, String> toJson() => {'question': question, 'answer': answer};
}

class QaResponse {
  QaResponse({
    required this.answerText,
    required this.citations,
    required this.grounded,
    this.refusalReason,
  });

  final String answerText;
  final List<Citation> citations;
  final bool grounded;
  final String? refusalReason;

  factory QaResponse.fromJson(Map<String, dynamic> json) {
    return QaResponse(
      answerText: _string(json['answerText']),
      citations: _list(json['citations'], Citation.tryParse),
      grounded: json['grounded'] == true,
      refusalReason: _optionalString(json['refusalReason']),
    );
  }
}

class EpisodePage {
  EpisodePage({required this.items, required this.nextCursor});

  final List<EpisodeSummary> items;
  final String? nextCursor;

  factory EpisodePage.fromJson(Map<String, dynamic> json) {
    return EpisodePage(
      items: _list(json['items'], EpisodeSummary.tryParse),
      nextCursor: _optionalString(json['nextCursor']),
    );
  }
}

class TranscribeEpisodeResult {
  TranscribeEpisodeResult({required this.jobId, required this.episode});

  /// Null when the episode was already ready, queued or processing.
  final String? jobId;
  final EpisodeSummary episode;

  factory TranscribeEpisodeResult.fromJson(Map<String, dynamic> json) {
    final episode = _map(json['episode']);
    final summary = episode == null ? null : EpisodeSummary.tryParse(episode);
    if (summary == null) {
      throw const FormatException('Transcribe response has no episode.');
    }
    return TranscribeEpisodeResult(
      jobId: _optionalString(json['jobId']),
      episode: summary,
    );
  }
}

class IngestJob {
  IngestJob({required this.status, this.error, this.updatedAt});

  final IngestJobStatus status;
  final String? error;
  final DateTime? updatedAt;

  factory IngestJob.fromJson(Map<String, dynamic> json) => IngestJob(
        status: ingestJobStatusFromString(json['status']),
        error: _optionalString(json['error']),
        updatedAt: _optionalDate(json['updatedAt']),
      );
}

class SourceSummary {
  SourceSummary({
    required this.id,
    required this.name,
    required this.rssUrl,
    this.imageUrl,
    this.createdAt,
    this.episodeCount = 0,
    this.readyEpisodeCount = 0,
    this.lastJob,
  });

  final String id;
  final String name;
  final String rssUrl;
  final String? imageUrl;
  final DateTime? createdAt;
  final int episodeCount;
  final int readyEpisodeCount;

  /// The latest import job; null when none has run.
  final IngestJob? lastJob;

  static SourceSummary? tryParse(Map<String, dynamic> json) =>
      _string(json['id']).isEmpty ? null : SourceSummary.fromJson(json);

  factory SourceSummary.fromJson(Map<String, dynamic> json) {
    final job = _map(json['lastJob']);
    final rssUrl = _string(json['rssUrl']);
    return SourceSummary(
      id: _string(json['id']),
      name: _optionalString(json['name']) ?? rssUrl,
      rssUrl: rssUrl,
      imageUrl: _optionalString(json['imageUrl']),
      createdAt: _optionalDate(json['createdAt']),
      episodeCount: _optionalInt(json['episodeCount']) ?? 0,
      readyEpisodeCount: _optionalInt(json['readyEpisodeCount']) ?? 0,
      lastJob: job == null ? null : IngestJob.fromJson(job),
    );
  }
}

class PodcastSearchResult {
  PodcastSearchResult({
    required this.title,
    required this.feedUrl,
    this.author,
    this.imageUrl,
    this.genre,
  });

  final String title;
  final String? author;
  final String feedUrl;
  final String? imageUrl;
  final String? genre;

  /// Returns null when [json] has no feed URL, which cannot be added.
  static PodcastSearchResult? tryParse(Map<String, dynamic> json) {
    final feedUrl = _optionalString(json['feedUrl']);
    if (feedUrl == null) return null;
    return PodcastSearchResult(
      title: _optionalString(json['title']) ?? feedUrl,
      feedUrl: feedUrl,
      author: _optionalString(json['author']),
      imageUrl: _optionalString(json['imageUrl']),
      genre: _optionalString(json['genre']),
    );
  }
}

/// Parses the `items` of a list response.
List<SourceSummary> parseSourceList(Map<String, dynamic> json) =>
    _list(json['items'], SourceSummary.tryParse);

List<PodcastSearchResult> parsePodcastSearch(Map<String, dynamic> json) =>
    _list(json['items'], PodcastSearchResult.tryParse);

class TranscriptionResult {
  TranscriptionResult({required this.text, required this.durationMs});

  final String text;
  final int durationMs;

  factory TranscriptionResult.fromJson(Map<String, dynamic> json) {
    return TranscriptionResult(
      text: _string(json['text']),
      durationMs: _optionalInt(json['durationMs']) ?? 0,
    );
  }
}

class SynthesizedAudio {
  SynthesizedAudio({required this.audioBase64, required this.mimeType});

  final String audioBase64;
  final String mimeType;

  factory SynthesizedAudio.fromJson(Map<String, dynamic> json) {
    return SynthesizedAudio(
      audioBase64: _string(json['audioBase64']),
      mimeType: _optionalString(json['mimeType']) ?? 'audio/mpeg',
    );
  }
}
