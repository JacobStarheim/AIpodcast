enum TranscriptionStatus { pending, ready, failed }

TranscriptionStatus transcriptionStatusFromString(String value) {
  switch (value) {
    case 'ready':
      return TranscriptionStatus.ready;
    case 'failed':
      return TranscriptionStatus.failed;
    default:
      return TranscriptionStatus.pending;
  }
}

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
  });

  final String id;
  final String sourceId;
  final String sourceName;
  final String title;
  final String description;
  final DateTime publishedAt;
  final String audioUrl;
  final TranscriptionStatus transcriptionStatus;

  factory EpisodeSummary.fromJson(Map<String, dynamic> json) {
    return EpisodeSummary(
      id: json['id'] as String,
      sourceId: json['sourceId'] as String,
      sourceName: json['sourceName'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      description: json['description'] as String? ?? '',
      publishedAt: DateTime.tryParse(json['publishedAt'] as String? ?? '') ?? DateTime.now(),
      audioUrl: json['audioUrl'] as String? ?? '',
      transcriptionStatus: transcriptionStatusFromString(
        json['transcriptionStatus'] as String? ?? 'pending',
      ),
    );
  }
}

class EpisodeDetail {
  EpisodeDetail({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.guid,
    required this.title,
    required this.description,
    required this.publishedAt,
    required this.audioUrl,
    required this.transcriptionStatus,
    required this.durationSec,
  });

  final String id;
  final String sourceId;
  final String sourceName;
  final String guid;
  final String title;
  final String description;
  final DateTime publishedAt;
  final String audioUrl;
  final TranscriptionStatus transcriptionStatus;
  final int? durationSec;

  factory EpisodeDetail.fromJson(Map<String, dynamic> json) {
    return EpisodeDetail(
      id: json['id'] as String,
      sourceId: json['sourceId'] as String,
      sourceName: json['sourceName'] as String? ?? '',
      guid: json['guid'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      description: json['description'] as String? ?? '',
      publishedAt: DateTime.tryParse(json['publishedAt'] as String? ?? '') ?? DateTime.now(),
      audioUrl: json['audioUrl'] as String? ?? '',
      transcriptionStatus: transcriptionStatusFromString(
        json['transcriptionStatus'] as String? ?? 'pending',
      ),
      durationSec: (json['durationSec'] as num?)?.toInt(),
    );
  }
}

class EpisodeDetailEnvelope {
  EpisodeDetailEnvelope({required this.episode, required this.transcriptionStatus});

  final EpisodeDetail episode;
  final TranscriptionStatus transcriptionStatus;

  factory EpisodeDetailEnvelope.fromJson(Map<String, dynamic> json) {
    return EpisodeDetailEnvelope(
      episode: EpisodeDetail.fromJson(json['episode'] as Map<String, dynamic>),
      transcriptionStatus: transcriptionStatusFromString(
        json['transcriptionStatus'] as String? ?? 'pending',
      ),
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
  });

  final String segmentId;
  final String episodeId;
  final String episodeTitle;
  final double startSec;
  final double endSec;
  final String text;
  final double score;

  factory Citation.fromJson(Map<String, dynamic> json) {
    return Citation(
      segmentId: json['segmentId'] as String,
      episodeId: json['episodeId'] as String,
      episodeTitle: json['episodeTitle'] as String? ?? '',
      startSec: (json['startSec'] as num?)?.toDouble() ?? 0,
      endSec: (json['endSec'] as num?)?.toDouble() ?? 0,
      text: json['text'] as String? ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0,
    );
  }
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
    final raw = (json['citations'] as List<dynamic>? ?? <dynamic>[])
        .map((item) => Citation.fromJson(item as Map<String, dynamic>))
        .toList();

    return QaResponse(
      answerText: json['answerText'] as String? ?? '',
      citations: raw,
      grounded: json['grounded'] as bool? ?? false,
      refusalReason: json['refusalReason'] as String?,
    );
  }
}

class EpisodePage {
  EpisodePage({required this.items, required this.nextCursor});

  final List<EpisodeSummary> items;
  final String? nextCursor;

  factory EpisodePage.fromJson(Map<String, dynamic> json) {
    final items = (json['items'] as List<dynamic>? ?? <dynamic>[])
        .map((item) => EpisodeSummary.fromJson(item as Map<String, dynamic>))
        .toList();

    return EpisodePage(items: items, nextCursor: json['nextCursor'] as String?);
  }
}

class TranscriptionResult {
  TranscriptionResult({required this.text, required this.durationMs});

  final String text;
  final int durationMs;

  factory TranscriptionResult.fromJson(Map<String, dynamic> json) {
    return TranscriptionResult(
      text: json['text'] as String? ?? '',
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class SynthesizedAudio {
  SynthesizedAudio({required this.audioBase64, required this.mimeType});

  final String audioBase64;
  final String mimeType;

  factory SynthesizedAudio.fromJson(Map<String, dynamic> json) {
    return SynthesizedAudio(
      audioBase64: json['audioBase64'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'audio/mpeg',
    );
  }
}
