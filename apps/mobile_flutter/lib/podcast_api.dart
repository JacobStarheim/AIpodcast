import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

abstract class PodcastApi {
  Future<EpisodePage> listEpisodes({String? cursor, int limit = 20});
  Future<EpisodeDetailEnvelope> getEpisode(String episodeId);
  Future<TranscriptionResult> transcribeVoiceFile(String audioPath);
  Future<QaResponse> askQuestion({
    required String questionText,
    String? episodeId,
    int topK = 5,
  });
  Future<SynthesizedAudio> synthesize(String text);
}

class HttpPodcastApi implements PodcastApi {
  HttpPodcastApi({
    required this.baseUrl,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 60),
  }) : _httpClient = httpClient ?? http.Client();

  final String baseUrl;
  final Duration requestTimeout;
  final http.Client _httpClient;

  Uri _uri(String path, [Map<String, String>? queryParameters]) {
    final trimmed = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$trimmed$path').replace(queryParameters: queryParameters);
  }

  Map<String, String> get _jsonHeaders => {'Content-Type': 'application/json'};

  @override
  Future<EpisodePage> listEpisodes({String? cursor, int limit = 20}) async {
    final query = <String, String>{'limit': '$limit'};
    if (cursor != null && cursor.isNotEmpty) {
      query['cursor'] = cursor;
    }

    final response = await _httpClient
        .get(_uri('/v1/episodes', query))
        .timeout(requestTimeout);
    _throwIfError(response);
    return EpisodePage.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<EpisodeDetailEnvelope> getEpisode(String episodeId) async {
    final response = await _httpClient
        .get(_uri('/v1/episodes/$episodeId'))
        .timeout(requestTimeout);
    _throwIfError(response);
    return EpisodeDetailEnvelope.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<TranscriptionResult> transcribeVoiceFile(String audioPath) async {
    final uri = _uri('/v1/voice/transcribe');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath));

    final response = await _httpClient
        .send(request)
        .then(http.Response.fromStream)
        .timeout(requestTimeout);
    _throwIfError(response);

    return TranscriptionResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<QaResponse> askQuestion({
    required String questionText,
    String? episodeId,
    int topK = 5,
  }) async {
    final payload = <String, dynamic>{
      'questionText': questionText,
      'topK': topK,
    };

    if (episodeId != null && episodeId.isNotEmpty) {
      payload['episodeId'] = episodeId;
    }

    final response = await _httpClient
        .post(
          _uri('/v1/qa/answer'),
          headers: _jsonHeaders,
          body: jsonEncode(payload),
        )
        .timeout(requestTimeout);

    _throwIfError(response);
    return QaResponse.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<SynthesizedAudio> synthesize(String text) async {
    final response = await _httpClient
        .post(
          _uri('/v1/voice/synthesize'),
          headers: _jsonHeaders,
          body: jsonEncode({'text': text}),
        )
        .timeout(requestTimeout);

    _throwIfError(response);
    return SynthesizedAudio.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  void _throwIfError(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
          'Request failed (${response.statusCode}): ${response.body}');
    }
  }
}
