import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_voice_ai/models.dart';
import 'package:podcast_voice_ai/podcast_api.dart';

const _episodeJson = <String, Object>{
  'id': 'ep1',
  'sourceId': 'source1',
  'sourceName': 'Sample podcast',
  'guid': 'episode-guid',
  'title': 'A useful episode',
  'description': 'About software',
  'publishedAt': '2026-01-02T12:00:00Z',
  'audioUrl': 'https://audio.example/ep1.mp3',
  'transcriptionStatus': 'ready',
  'durationSec': 1800,
};

http.Response _jsonResponse(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  group('HttpPodcastApi', () {
    late Directory fixtureDirectory;
    late File audioFile;
    const audioBytes = <int>[0, 1, 2, 127, 128, 254, 255];

    setUpAll(() async {
      fixtureDirectory = await Directory.systemTemp.createTemp('podcast_api_');
      audioFile = File('${fixtureDirectory.path}/question.m4a');
      await audioFile.writeAsBytes(audioBytes);
    });

    tearDownAll(() => fixtureDirectory.delete(recursive: true));

    HttpPodcastApi apiWith(
      http.Client client, {
      Duration requestTimeout = const Duration(seconds: 60),
    }) {
      addTearDown(client.close);
      return HttpPodcastApi(
        baseUrl: 'https://api.example/',
        httpClient: client,
        requestTimeout: requestTimeout,
      );
    }

    test('lists episodes with encoded pagination and maps the response',
        () async {
      final api = apiWith(MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.origin, 'https://api.example');
        expect(request.url.path, '/v1/episodes');
        expect(request.url.queryParameters, {
          'limit': '7',
          'cursor': 'next+/= &',
        });
        return _jsonResponse({
          'items': [_episodeJson],
          'nextCursor': 'page-3',
        });
      }));

      final page = await api.listEpisodes(cursor: 'next+/= &', limit: 7);

      expect(page.nextCursor, 'page-3');
      expect(page.items, hasLength(1));
      final episode = page.items.single;
      expect(episode.id, 'ep1');
      expect(episode.sourceId, 'source1');
      expect(episode.sourceName, 'Sample podcast');
      expect(episode.title, 'A useful episode');
      expect(episode.description, 'About software');
      expect(episode.publishedAt, DateTime.utc(2026, 1, 2, 12));
      expect(episode.audioUrl, 'https://audio.example/ep1.mp3');
      expect(episode.transcriptionStatus, TranscriptionStatus.ready);
    });

    test('omits an absent or empty cursor and uses the default page size',
        () async {
      var calls = 0;
      final api = apiWith(MockClient((request) async {
        calls++;
        expect(request.url.queryParameters, {'limit': '20'});
        return _jsonResponse({'items': <Object>[], 'nextCursor': null});
      }));

      expect((await api.listEpisodes()).items, isEmpty);
      expect((await api.listEpisodes(cursor: '')).nextCursor, isNull);
      expect(calls, 2);
    });

    test('gets episode detail and its transcript status', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), 'https://api.example/v1/episodes/ep1');
        return _jsonResponse({
          'episode': _episodeJson,
          'transcriptionStatus': 'ready',
        });
      }));

      final detail = await api.getEpisode('ep1');

      expect(detail.transcriptionStatus, TranscriptionStatus.ready);
      expect(detail.episode.id, 'ep1');
      expect(detail.episode.guid, 'episode-guid');
      expect(detail.episode.durationSec, 1800);
      expect(detail.episode.audioUrl, 'https://audio.example/ep1.mp3');
    });

    test('posts a scoped question and maps grounded citations', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), 'https://api.example/v1/qa/answer');
        expect(request.headers['content-type'], startsWith('application/json'));
        expect(jsonDecode(request.body), {
          'questionText': 'Hva sa verten?',
          'episodeId': 'ep1',
          'topK': 3,
        });
        return _jsonResponse({
          'answerText': 'Verten snakket om arkitektur.',
          'grounded': true,
          'citations': [
            {
              'segmentId': 'segment1',
              'episodeId': 'ep1',
              'episodeTitle': 'A useful episode',
              'startSec': 12.5,
              'endSec': 18,
              'text': 'Architecture matters.',
              'score': 0.9,
            },
          ],
        });
      }));

      final answer = await api.askQuestion(
        questionText: 'Hva sa verten?',
        episodeId: 'ep1',
        topK: 3,
      );

      expect(answer.answerText, 'Verten snakket om arkitektur.');
      expect(answer.grounded, isTrue);
      expect(answer.refusalReason, isNull);
      final citation = answer.citations.single;
      expect(citation.segmentId, 'segment1');
      expect(citation.episodeId, 'ep1');
      expect(citation.episodeTitle, 'A useful episode');
      expect(citation.startSec, 12.5);
      expect(citation.endSec, 18.0);
      expect(citation.text, 'Architecture matters.');
      expect(citation.score, 0.9);
    });

    test('omits absent episode scope and preserves refusal responses',
        () async {
      final api = apiWith(MockClient((request) async {
        expect(jsonDecode(request.body), {
          'questionText': 'Unanswerable question',
          'topK': 5,
        });
        return _jsonResponse({
          'answerText': 'There is not enough evidence.',
          'grounded': false,
          'citations': <Object>[],
          'refusalReason': 'insufficient_retrieval_confidence',
        });
      }));

      for (final episodeId in <String?>[null, '']) {
        final answer = await api.askQuestion(
          questionText: 'Unanswerable question',
          episodeId: episodeId,
        );
        expect(answer.grounded, isFalse);
        expect(answer.citations, isEmpty);
        expect(answer.refusalReason, 'insufficient_retrieval_confidence');
      }
    });

    test('synthesizes speech and preserves the returned audio/wav MIME type',
        () async {
      final api = apiWith(MockClient((request) async {
        expect(request.method, 'POST');
        expect(
            request.url.toString(), 'https://api.example/v1/voice/synthesize');
        expect(request.headers['content-type'], startsWith('application/json'));
        expect(jsonDecode(request.body), {'text': 'Her er svaret ditt.'});
        return _jsonResponse({
          'audioBase64': base64Encode(audioBytes),
          'mimeType': 'audio/wav',
        });
      }));

      final audio = await api.synthesize('Her er svaret ditt.');

      expect(audio.mimeType, 'audio/wav');
      expect(base64Decode(audio.audioBase64), audioBytes);
    });

    test('uploads the recording through the injected client as multipart audio',
        () async {
      var calls = 0;
      final api = apiWith(MockClient.streaming((request, bodyStream) async {
        calls++;
        expect(request.method, 'POST');
        expect(
            request.url.toString(), 'https://api.example/v1/voice/transcribe');
        final contentType = request.headers['content-type']!;
        expect(contentType, startsWith('multipart/form-data; boundary='));
        final boundary = contentType.split('boundary=').last;
        final multipart = latin1.decode(await bodyStream.toBytes());
        expect(
          multipart,
          contains(
              'content-disposition: form-data; name="audio"; filename="question.m4a"'),
        );
        final fileBody = multipart.split('\r\n\r\n')[1];
        expect(fileBody, '${latin1.decode(audioBytes)}\r\n--$boundary--\r\n');
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({
            'text': 'Hva handlet episoden om?',
            'durationMs': 1500,
          }))),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }));

      final transcript = await api.transcribeVoiceFile(audioFile.path);

      expect(calls, 1);
      expect(transcript.text, 'Hva handlet episoden om?');
      expect(transcript.durationMs, 1500);
    });

    final operations =
        <String, Future<Object?> Function(HttpPodcastApi, String)>{
      'listEpisodes': (api, _) => api.listEpisodes(),
      'getEpisode': (api, _) => api.getEpisode('ep1'),
      'askQuestion': (api, _) => api.askQuestion(questionText: 'Question?'),
      'synthesize': (api, _) => api.synthesize('Answer.'),
      'transcribeVoiceFile': (api, path) => api.transcribeVoiceFile(path),
    };

    for (final operation in operations.entries) {
      for (final status in [400, 503]) {
        test('${operation.key} reports HTTP $status before parsing JSON',
            () async {
          final api = apiWith(MockClient((_) async {
            return http.Response('upstream unavailable', status);
          }));

          await expectLater(
            operation.value(api, audioFile.path),
            throwsA(isA<HttpException>().having(
              (error) => error.message,
              'message',
              'Request failed ($status): upstream unavailable',
            )),
          );
        });
      }

      test('${operation.key} times out with the configured deadline', () async {
        final response = Completer<http.Response>();
        addTearDown(() => response.complete(_jsonResponse({})));
        const deadline = Duration(milliseconds: 10);
        final api = apiWith(
          MockClient((_) => response.future),
          requestTimeout: deadline,
        );

        await expectLater(
          operation.value(api, audioFile.path),
          throwsA(isA<TimeoutException>().having(
            (error) => error.duration,
            'duration',
            deadline,
          )),
        );
      });
    }

    test('transcription timeout also covers a stalled response body', () async {
      final responseBody = StreamController<List<int>>();
      addTearDown(responseBody.close);
      final api = apiWith(
        MockClient.streaming((_, requestBody) async {
          await requestBody.drain<void>();
          return http.StreamedResponse(responseBody.stream, 200);
        }),
        requestTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        api.transcribeVoiceFile(audioFile.path),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
