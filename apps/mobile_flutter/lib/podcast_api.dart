import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

abstract class PodcastApi {
  Future<EpisodePage> listEpisodes({
    String? cursor,
    int limit = 20,
    String? sourceId,
    String? query,
    Set<TranscriptionStatus>? statuses,
  });
  Future<EpisodeDetailEnvelope> getEpisode(String episodeId);

  /// Requests transcription; the episode comes back `queued` or unchanged.
  Future<TranscribeEpisodeResult> transcribeEpisode(String episodeId);
  Future<List<PodcastSearchResult>> searchPodcasts(String query);
  Future<List<SourceSummary>> listSources();
  Future<SourceSummary> addSource({
    required String rssUrl,
    String? name,
    String? imageUrl,
  });
  Future<TranscriptionResult> transcribeVoiceFile(String audioPath);

  /// Omit [episodeId] to search every ready episode in the library.
  /// [positionSec] only applies together with [episodeId].
  Future<QaResponse> askQuestion({
    required String questionText,
    String? episodeId,
    double? positionSec,
    List<QaTurn> history = const <QaTurn>[],
    int topK = 10,
  });
  Future<SynthesizedAudio> synthesize(String text);
}

/// A non-2xx API response. [userMessage] is safe to show in the app.
class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    this.serverMessage,
    this.requestId,
    this.retryAfter,
  });

  /// Parses the `{ error, requestId? }` body and the `Retry-After` header.
  factory ApiException.fromResponse(http.Response response) {
    String? message;
    String? requestId;
    try {
      final body = jsonDecode(_utf8Body(response));
      if (body is Map) {
        if (body['error'] is String) message = body['error'] as String;
        if (body['requestId'] is String) {
          requestId = body['requestId'] as String;
        }
      }
    } on FormatException {
      // A proxy or crash page, not an API error body. Never show it.
    }
    return ApiException(
      statusCode: response.statusCode,
      serverMessage: message,
      requestId: requestId,
      retryAfter: parseRetryAfter(response.headers['retry-after']),
    );
  }

  final int statusCode;
  final String? serverMessage;
  final String? requestId;
  final Duration? retryAfter;

  String get userMessage {
    switch (statusCode) {
      case 400:
        return _readableServerMessage ??
            'The server couldn’t use that request. Please check it and try again.';
      case 401:
      case 403:
        return 'The server didn’t accept this app’s key. Check the API_KEY setting.';
      case 404:
        return 'That item is no longer available. Refresh and try again.';
      case 409:
        return 'This episode isn’t ready for questions yet.';
      case 413:
        return 'That recording is too long. Try a shorter question.';
      case 429:
        final wait = retryAfter;
        if (wait == null) return 'Too many requests, try again in a moment.';
        final seconds = (wait.inMilliseconds / 1000).ceil().clamp(1, 86400);
        return 'Too many requests, try again in $seconds s.';
    }
    if (statusCode >= 500) {
      return 'The server had a problem. Please try again in a moment.';
    }
    return 'The request failed (HTTP $statusCode). Please try again.';
  }

  /// A short, sentence-like server explanation (for 400s), never a raw body
  /// or an error code such as `not_found`.
  String? get _readableServerMessage {
    final message = serverMessage?.trim();
    if (message == null ||
        message.isEmpty ||
        message.length > 160 ||
        !message.contains(' ')) {
      return null;
    }
    return RegExp(r'[.!?]$').hasMatch(message) ? message : '$message.';
  }

  @override
  String toString() => 'ApiException($statusCode): ${serverMessage ?? ''}'
      '${requestId != null ? ' (requestId: $requestId)' : ''}';
}

/// JSON is UTF-8 even when a response omits the charset (where
/// [http.Response.body] would fall back to Latin-1).
String _utf8Body(http.Response response) =>
    utf8.decode(response.bodyBytes, allowMalformed: true);

/// Parses a `Retry-After` value: delay seconds or an HTTP date.
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null || value.trim().isEmpty) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
  try {
    final date = HttpDate.parse(value.trim());
    final delay = date.difference(now ?? DateTime.now());
    return delay.isNegative ? Duration.zero : delay;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}

/// A short human message for [error]; [fallback] covers unexpected errors.
String describeError(Object error, {required String fallback}) {
  if (error is ApiException) return error.userMessage;
  if (error is TimeoutException) {
    return 'The server took too long to respond. Please try again.';
  }
  if (error is SocketException || error is http.ClientException) {
    return 'Couldn’t reach the server. Check your connection and try again.';
  }
  return fallback;
}

class HttpPodcastApi implements PodcastApi {
  HttpPodcastApi({
    required this.baseUrl,
    this.apiKey = '',
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 60),
  }) : _httpClient = httpClient ?? http.Client();

  final String baseUrl;

  /// Shared app key sent as `Authorization: Bearer <key>`.
  final String apiKey;
  final Duration requestTimeout;
  final http.Client _httpClient;

  Uri _uri(String path, [Map<String, String>? queryParameters]) {
    final trimmed = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$trimmed$path').replace(queryParameters: queryParameters);
  }

  Map<String, String> get _authHeaders =>
      apiKey.isEmpty ? <String, String>{} : {'Authorization': 'Bearer $apiKey'};

  Map<String, String> get _jsonHeaders =>
      {..._authHeaders, 'Content-Type': 'application/json'};

  Future<Map<String, dynamic>> _get(String path,
      [Map<String, String>? query]) async {
    final response = await _httpClient
        .get(_uri(path, query), headers: _authHeaders)
        .timeout(requestTimeout);
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(String path, [Object? body]) async {
    final response = await _httpClient
        .post(
          _uri(path),
          headers: body == null ? _authHeaders : _jsonHeaders,
          body: body == null ? null : jsonEncode(body),
        )
        .timeout(requestTimeout);
    return _decode(response);
  }

  @override
  Future<EpisodePage> listEpisodes({
    String? cursor,
    int limit = 20,
    String? sourceId,
    String? query,
    Set<TranscriptionStatus>? statuses,
  }) async {
    final parameters = <String, String>{'limit': '$limit'};
    if (cursor != null && cursor.isNotEmpty) parameters['cursor'] = cursor;
    if (sourceId != null && sourceId.isNotEmpty) {
      parameters['sourceId'] = sourceId;
    }
    final text = query?.trim();
    if (text != null && text.isNotEmpty) parameters['q'] = text;
    if (statuses != null && statuses.isNotEmpty) {
      parameters['status'] = statuses.map((status) => status.name).join(',');
    }
    return EpisodePage.fromJson(await _get('/v1/episodes', parameters));
  }

  @override
  Future<EpisodeDetailEnvelope> getEpisode(String episodeId) async =>
      EpisodeDetailEnvelope.fromJson(
          await _get('/v1/episodes/${Uri.encodeComponent(episodeId)}'));

  @override
  Future<TranscribeEpisodeResult> transcribeEpisode(String episodeId) async =>
      TranscribeEpisodeResult.fromJson(await _post(
          '/v1/episodes/${Uri.encodeComponent(episodeId)}/transcribe'));

  @override
  Future<List<PodcastSearchResult>> searchPodcasts(String query) async =>
      parsePodcastSearch(
          await _get('/v1/podcasts/search', {'q': query.trim()}));

  @override
  Future<List<SourceSummary>> listSources() async =>
      parseSourceList(await _get('/v1/sources'));

  @override
  Future<SourceSummary> addSource({
    required String rssUrl,
    String? name,
    String? imageUrl,
  }) async {
    final body = <String, String>{'rssUrl': rssUrl};
    if (name != null && name.trim().isNotEmpty) body['name'] = name.trim();
    if (imageUrl != null && imageUrl.isNotEmpty) body['imageUrl'] = imageUrl;
    final source = SourceSummary.tryParse(await _post('/v1/sources', body));
    if (source == null) {
      throw const FormatException('Source response has no id.');
    }
    return source;
  }

  @override
  Future<TranscriptionResult> transcribeVoiceFile(String audioPath) async {
    final uri = _uri('/v1/voice/transcribe');
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_authHeaders)
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath));

    final response = await _httpClient
        .send(request)
        .then(http.Response.fromStream)
        .timeout(requestTimeout);
    return TranscriptionResult.fromJson(_decode(response));
  }

  @override
  Future<QaResponse> askQuestion({
    required String questionText,
    String? episodeId,
    double? positionSec,
    List<QaTurn> history = const <QaTurn>[],
    int topK = 10,
  }) async {
    final payload = <String, dynamic>{
      'questionText': questionText,
      'topK': topK,
    };
    if (episodeId != null && episodeId.isNotEmpty) {
      payload['episodeId'] = episodeId;
      if (positionSec != null && positionSec.isFinite && positionSec >= 0) {
        payload['positionSec'] = positionSec;
      }
    }
    if (history.isNotEmpty) {
      payload['history'] = [for (final turn in history) turn.toJson()];
    }
    return QaResponse.fromJson(await _post('/v1/qa/answer', payload));
  }

  @override
  Future<SynthesizedAudio> synthesize(String text) async =>
      SynthesizedAudio.fromJson(
          await _post('/v1/voice/synthesize', {'text': text}));

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException.fromResponse(response);
    }
    final body = jsonDecode(_utf8Body(response));
    if (body is! Map) {
      throw const FormatException('Expected a JSON object response.');
    }
    return body.cast<String, dynamic>();
  }
}
