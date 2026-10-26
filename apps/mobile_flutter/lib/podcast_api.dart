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

  /// Transcription minutes used today and the daily limit.
  Future<TranscriptionUsage> getUsage();
  Future<List<PodcastSearchResult>> searchPodcasts(String query);
  Future<List<SourceSummary>> listSources();
  Future<SourceSummary> addSource({
    required String rssUrl,
    String? name,
    String? imageUrl,
  });

  /// Turns automatic transcription of new episodes on or off.
  Future<SourceSummary> updateSource(String sourceId,
      {required bool autoTranscribe});

  /// [episodeId] lets the server use names from that episode as spelling
  /// hints.
  Future<TranscriptionResult> transcribeVoiceFile(String audioPath,
      {String? episodeId});

  /// Answers a question as server-sent events: status changes, answer text
  /// as it is written, then exactly one [QaDoneEvent] or [QaErrorEvent].
  ///
  /// Omit [episodeId] to search every ready episode in the library.
  /// [positionSec] only applies together with [episodeId].
  Stream<QaStreamEvent> askQuestionStream({
    required String questionText,
    String? episodeId,
    double? positionSec,
    List<QaTurn> history = const <QaTurn>[],
    int topK = 10,
  });
  Future<SynthesizedAudio> synthesize(String text);
}

/// Signing in and out. Kept apart from [PodcastApi] because it is used
/// before there is a session.
abstract class AuthApi {
  /// Throws an [ApiException] with status 401 for a wrong email or password.
  Future<LoginResult> login({required String email, required String password});

  /// Revokes [token] on the server.
  Future<void> logout(String token);

  /// The signed-in user for the current token.
  Future<User> me();
}

/// The `code` of a 429 response when today's transcription minutes are used.
const transcriptionBudgetExceeded = 'transcription_budget_exceeded';

/// A non-2xx API response. [userMessage] is safe to show in the app.
class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    this.serverMessage,
    this.code,
    this.requestId,
    this.retryAfter,
  });

  /// Parses the `{ error, code?, requestId? }` body and the `Retry-After`
  /// header.
  factory ApiException.fromResponse(http.Response response) {
    String? message;
    String? code;
    String? requestId;
    try {
      final body = jsonDecode(_utf8Body(response));
      if (body is Map) {
        if (body['error'] is String) message = body['error'] as String;
        if (body['code'] is String) code = body['code'] as String;
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
      code: code,
      requestId: requestId,
      retryAfter: parseRetryAfter(response.headers['retry-after']),
    );
  }

  final int statusCode;
  final String? serverMessage;

  /// Machine-readable reason, e.g. [transcriptionBudgetExceeded].
  final String? code;
  final String? requestId;
  final Duration? retryAfter;

  bool get isTranscriptionBudgetExceeded =>
      statusCode == 429 && code == transcriptionBudgetExceeded;

  String get userMessage {
    if (isTranscriptionBudgetExceeded) {
      return 'Today’s transcription limit is used up. Try again tomorrow.';
    }
    switch (statusCode) {
      case 400:
        return _readableServerMessage ??
            'The server couldn’t use that request. Please check it and try again.';
      case 401:
        return 'Your session has ended. Please sign in again.';
      case 403:
        return 'Your account doesn’t have access to that.';
      case 404:
        return 'That item is no longer available. Refresh and try again.';
      case 409:
        return 'This episode isn’t ready for questions yet.';
      case 413:
        return 'That recording is too long. Try a shorter question.';
      case 429:
        final wait = retryAfter;
        if (wait == null) return 'Too many requests, try again in a moment.';
        return 'Too many requests, try again in ${waitLabel(wait)}.';
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
  String toString() =>
      'ApiException($statusCode${code == null ? '' : ', $code'})'
      ': ${serverMessage ?? ''}'
      '${requestId != null ? ' (requestId: $requestId)' : ''}';
}

/// `12 s` below 90 seconds, otherwise whole minutes such as `15 min`.
String waitLabel(Duration wait) {
  final seconds = (wait.inMilliseconds / 1000).ceil().clamp(1, 86400);
  if (seconds < 90) return '$seconds s';
  return '${(seconds / 60).ceil()} min';
}

/// The answer stream ended with an `error` event or without an answer.
class AnswerStreamException implements Exception {
  const AnswerStreamException({this.serverMessage, this.requestId});

  final String? serverMessage;
  final String? requestId;

  String get userMessage =>
      'The answer couldn’t be finished. Please try again.';

  @override
  String toString() => 'AnswerStreamException: ${serverMessage ?? 'incomplete'}'
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
  if (error is AnswerStreamException) return error.userMessage;
  if (error is TimeoutException) {
    return 'The server took too long to respond. Please try again.';
  }
  if (error is SocketException || error is http.ClientException) {
    return 'Couldn’t reach the server. Check your connection and try again.';
  }
  return fallback;
}

/// Resolves [url] from a response against the configured API [baseUrl].
///
/// Absolute URLs are kept. A path such as `/v1/media/...` is appended to the
/// base URL the same way the app builds request paths, so it also works
/// when the API is served under a path prefix.
String resolveApiUrl(String baseUrl, String url) {
  final value = url.trim();
  if (value.isEmpty) return value;
  final parsed = Uri.tryParse(value);
  if (parsed != null && parsed.hasScheme) return value;
  final base = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  if (value.startsWith('//')) {
    return '${Uri.parse(base).scheme}:$value';
  }
  if (value.startsWith('/')) return '$base$value';
  return Uri.parse('$base/').resolve(value).toString();
}

/// The `data` of each server-sent event in [bytes].
///
/// Chunks may split lines, UTF-8 characters and events anywhere. Multiple
/// `data:` lines of one event are joined with a newline; comments and other
/// fields are ignored. A final event without its blank line is still
/// delivered.
Stream<String> serverSentEventData(Stream<List<int>> bytes) async* {
  final data = StringBuffer();
  var hasData = false;
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (hasData) yield data.toString();
      data.clear();
      hasData = false;
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    if (field != 'data') continue;
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (hasData) data.write('\n');
    data.write(value);
    hasData = true;
  }
  if (hasData) yield data.toString();
}

/// Parses the answer stream in [bytes] and ends after the final `done` or
/// `error` event. Data that is not a known JSON event is skipped.
Stream<QaStreamEvent> parseAnswerStream(Stream<List<int>> bytes) async* {
  await for (final data in serverSentEventData(bytes)) {
    Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException {
      continue;
    }
    if (json is! Map) continue;
    final event = QaStreamEvent.tryParse(json.cast<String, dynamic>());
    if (event == null) continue;
    yield event;
    if (event is QaDoneEvent || event is QaErrorEvent) return;
  }
}

class HttpPodcastApi implements PodcastApi, AuthApi {
  /// Requests send `Authorization: Bearer <token>` with the token from
  /// [authToken] (the signed-in session) or else the fixed [apiKey].
  /// [onUnauthorized] receives the token of any request that got `401`
  /// (other than signing in).
  HttpPodcastApi({
    required this.baseUrl,
    String apiKey = '',
    String? Function()? authToken,
    this.onUnauthorized,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 60),
  })  : _authToken = authToken ?? (() => apiKey),
        _httpClient = httpClient ?? http.Client();

  final String baseUrl;
  final String? Function() _authToken;
  final void Function(String? rejectedToken)? onUnauthorized;
  final Duration requestTimeout;
  final http.Client _httpClient;

  Uri _uri(String path, [Map<String, String>? queryParameters]) {
    final trimmed = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$trimmed$path').replace(queryParameters: queryParameters);
  }

  String _resolve(String url) => resolveApiUrl(baseUrl, url);

  String? get _token {
    final token = _authToken();
    return token == null || token.isEmpty ? null : token;
  }

  Map<String, String> _authHeaders(String? token) =>
      token == null ? <String, String>{} : {'Authorization': 'Bearer $token'};

  Map<String, String> _jsonHeaders(String? token) =>
      {..._authHeaders(token), 'Content-Type': 'application/json'};

  Future<Map<String, dynamic>> _get(String path,
      [Map<String, String>? query]) async {
    final token = _token;
    final response = await _httpClient
        .get(_uri(path, query), headers: _authHeaders(token))
        .timeout(requestTimeout);
    return _decode(response, token);
  }

  Future<Map<String, dynamic>> _post(String path, [Object? body]) async {
    final token = _token;
    final response = await _httpClient
        .post(
          _uri(path),
          headers: body == null ? _authHeaders(token) : _jsonHeaders(token),
          body: body == null ? null : jsonEncode(body),
        )
        .timeout(requestTimeout);
    return _decode(response, token);
  }

  @override
  Future<LoginResult> login(
      {required String email, required String password}) async {
    final response = await _httpClient
        .post(
          _uri('/v1/auth/login'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(requestTimeout);
    // A 401 here means wrong credentials, not an ended session.
    return LoginResult.fromJson(
        _decode(response, null, reportUnauthorized: false));
  }

  @override
  Future<void> logout(String token) async {
    final response = await _httpClient
        .post(_uri('/v1/auth/logout'), headers: _authHeaders(token))
        .timeout(requestTimeout);
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    // The session is over either way; never sign out a newer session.
    throw ApiException.fromResponse(response);
  }

  @override
  Future<User> me() async {
    final user = User.tryParse(await _get('/v1/me'));
    if (user == null) throw const FormatException('User response has no id.');
    return user;
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
    return EpisodePage.fromJson(await _get('/v1/episodes', parameters),
        resolveUrl: _resolve);
  }

  @override
  Future<EpisodeDetailEnvelope> getEpisode(String episodeId) async =>
      EpisodeDetailEnvelope.fromJson(
          await _get('/v1/episodes/${Uri.encodeComponent(episodeId)}'),
          resolveUrl: _resolve);

  @override
  Future<TranscribeEpisodeResult> transcribeEpisode(String episodeId) async =>
      TranscribeEpisodeResult.fromJson(
          await _post(
              '/v1/episodes/${Uri.encodeComponent(episodeId)}/transcribe'),
          resolveUrl: _resolve);

  @override
  Future<TranscriptionUsage> getUsage() async =>
      TranscriptionUsage.fromJson(await _get('/v1/usage'));

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
  Future<SourceSummary> updateSource(String sourceId,
      {required bool autoTranscribe}) async {
    final token = _token;
    final response = await _httpClient
        .patch(
          _uri('/v1/sources/${Uri.encodeComponent(sourceId)}'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'autoTranscribe': autoTranscribe}),
        )
        .timeout(requestTimeout);
    final source = SourceSummary.tryParse(_decode(response, token));
    if (source == null) {
      throw const FormatException('Source response has no id.');
    }
    return source;
  }

  @override
  Future<TranscriptionResult> transcribeVoiceFile(String audioPath,
      {String? episodeId}) async {
    final token = _token;
    final request = http.MultipartRequest('POST', _uri('/v1/voice/transcribe'))
      ..headers.addAll(_authHeaders(token))
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath));
    if (episodeId != null && episodeId.isNotEmpty) {
      request.fields['episodeId'] = episodeId;
    }

    final response = await _httpClient
        .send(request)
        .then(http.Response.fromStream)
        .timeout(requestTimeout);
    return TranscriptionResult.fromJson(_decode(response, token));
  }

  Map<String, dynamic> _questionPayload({
    required String questionText,
    String? episodeId,
    double? positionSec,
    List<QaTurn> history = const <QaTurn>[],
    int topK = 10,
  }) {
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
    return payload;
  }

  @override
  Stream<QaStreamEvent> askQuestionStream({
    required String questionText,
    String? episodeId,
    double? positionSec,
    List<QaTurn> history = const <QaTurn>[],
    int topK = 10,
  }) async* {
    final token = _token;
    final request = http.Request('POST', _uri('/v1/qa/answer/stream'))
      ..headers.addAll({
        ..._jsonHeaders(token),
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode(_questionPayload(
        questionText: questionText,
        episodeId: episodeId,
        positionSec: positionSec,
        history: history,
        topK: topK,
      ));
    final response = await _httpClient.send(request).timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Validation errors before streaming starts are normal JSON errors.
      final body =
          await http.Response.fromStream(response).timeout(requestTimeout);
      throw _failure(body, token);
    }
    // The deadline applies to each wait for more of the stream.
    yield* parseAnswerStream(response.stream.timeout(requestTimeout));
  }

  @override
  Future<SynthesizedAudio> synthesize(String text) async =>
      SynthesizedAudio.fromJson(
          await _post('/v1/voice/synthesize', {'text': text}));

  ApiException _failure(http.Response response, String? token,
      {bool reportUnauthorized = true}) {
    final error = ApiException.fromResponse(response);
    if (error.statusCode == 401 && reportUnauthorized) {
      onUnauthorized?.call(token);
    }
    return error;
  }

  Map<String, dynamic> _decode(http.Response response, String? token,
      {bool reportUnauthorized = true}) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _failure(response, token, reportUnauthorized: reportUnauthorized);
    }
    final body = jsonDecode(_utf8Body(response));
    if (body is! Map) {
      throw const FormatException('Expected a JSON object response.');
    }
    return body.cast<String, dynamic>();
  }
}
