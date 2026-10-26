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
      String apiKey = 'test-key',
    }) {
      addTearDown(client.close);
      return HttpPodcastApi(
        baseUrl: 'https://api.example/',
        apiKey: apiKey,
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
          'topK': 6,
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
      'transcribeEpisode': (api, _) => api.transcribeEpisode('ep1'),
      'searchPodcasts': (api, _) => api.searchPodcasts('history'),
      'listSources': (api, _) => api.listSources(),
      'addSource': (api, _) =>
          api.addSource(rssUrl: 'https://feeds.example/a.xml'),
      'askQuestion': (api, _) => api.askQuestion(questionText: 'Question?'),
      'synthesize': (api, _) => api.synthesize('Answer.'),
      'transcribeVoiceFile': (api, path) => api.transcribeVoiceFile(path),
    };

    for (final operation in operations.entries) {
      test('${operation.key} sends the app key', () async {
        String? authorization;
        final api = apiWith(MockClient.streaming((request, body) async {
          await body.drain<void>();
          authorization = request.headers['authorization'] ??
              request.headers['Authorization'];
          return http.StreamedResponse(Stream.value(utf8.encode('{}')), 500);
        }));
        await expectLater(
            operation.value(api, audioFile.path), throwsA(isA<ApiException>()));
        expect(authorization, 'Bearer test-key');
      });

      for (final status in [400, 503]) {
        test('${operation.key} reports HTTP $status before parsing JSON',
            () async {
          final api = apiWith(MockClient((_) async {
            return http.Response('<html>upstream unavailable</html>', status);
          }));

          await expectLater(
            operation.value(api, audioFile.path),
            throwsA(isA<ApiException>()
                .having((error) => error.statusCode, 'statusCode', status)
                .having((error) => error.userMessage, 'userMessage',
                    isNot(contains('upstream')))),
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

    test('omits the authorization header when no key is configured',
        () async {
      final api = apiWith(
        MockClient((request) async {
          expect(request.headers.containsKey('authorization'), isFalse);
          expect(request.headers.containsKey('Authorization'), isFalse);
          return _jsonResponse({'items': <Object>[]});
        }),
        apiKey: '',
      );
      expect(await api.listSources(), isEmpty);
    });

    test('lists episodes with source, search and status filters', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.url.queryParameters, {
          'limit': '20',
          'sourceId': 'src 1',
          'q': 'climate',
          'status': 'queued,processing',
        });
        return _jsonResponse({'items': <Object>[], 'nextCursor': null});
      }));
      await api.listEpisodes(
        sourceId: 'src 1',
        query: '  climate ',
        statuses: {
          TranscriptionStatus.queued,
          TranscriptionStatus.processing,
        },
      );
    });

    test('maps the new episode fields', () async {
      final api = apiWith(MockClient((request) async {
        return _jsonResponse({
          'items': [
            {
              ..._episodeJson,
              'imageUrl': 'https://img.example/ep1.jpg',
              'transcriptionStatus': 'failed',
              'transcriptionError': 'Audio download failed',
            },
          ],
          'nextCursor': null,
        });
      }));
      final episode = (await api.listEpisodes()).items.single;
      expect(episode.imageUrl, 'https://img.example/ep1.jpg');
      expect(episode.durationSec, 1800);
      expect(episode.transcriptionStatus, TranscriptionStatus.failed);
      expect(episode.transcriptionError, 'Audio download failed');
    });

    test('requests transcription with an empty POST', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(),
            'https://api.example/v1/episodes/ep%201/transcribe');
        expect(request.body, isEmpty);
        expect(request.headers['content-type'], isNull);
        return http.Response(
            jsonEncode({
              'jobId': 'job-7',
              'episode': {..._episodeJson, 'transcriptionStatus': 'queued'},
            }),
            202);
      }));
      final result = await api.transcribeEpisode('ep 1');
      expect(result.jobId, 'job-7');
      expect(result.episode.transcriptionStatus, TranscriptionStatus.queued);
    });

    test('an already transcribed episode returns no job', () async {
      final api = apiWith(MockClient((request) async {
        return _jsonResponse({'jobId': null, 'episode': _episodeJson});
      }));
      final result = await api.transcribeEpisode('ep1');
      expect(result.jobId, isNull);
      expect(result.episode.transcriptionStatus, TranscriptionStatus.ready);
    });

    test('searches the podcast directory', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.url.path, '/v1/podcasts/search');
        expect(request.url.queryParameters, {'q': 'hard fork'});
        return _jsonResponse({
          'items': [
            {
              'title': 'Hard Fork',
              'author': 'The New York Times',
              'feedUrl': 'https://feeds.example/hardfork',
              'imageUrl': 'https://img.example/hf.jpg',
              'genre': 'Technology',
            },
            {'title': 'No feed'},
          ],
        });
      }));
      final results = await api.searchPodcasts(' hard fork ');
      expect(results, hasLength(1));
      expect(results.single.title, 'Hard Fork');
      expect(results.single.author, 'The New York Times');
      expect(results.single.feedUrl, 'https://feeds.example/hardfork');
      expect(results.single.imageUrl, 'https://img.example/hf.jpg');
      expect(results.single.genre, 'Technology');
    });

    test('lists sources with their import state', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.url.toString(), 'https://api.example/v1/sources');
        return _jsonResponse({
          'items': [
            {
              'id': 'src1',
              'name': 'Sample podcast',
              'rssUrl': 'https://feeds.example/sample',
              'imageUrl': null,
              'createdAt': '2026-01-01T00:00:00Z',
              'episodeCount': 40,
              'readyEpisodeCount': 3,
              'lastJob': {
                'status': 'failed',
                'error': 'Feed returned 404',
                'updatedAt': '2026-01-02T00:00:00Z',
              },
            },
          ],
        });
      }));
      final source = (await api.listSources()).single;
      expect(source.id, 'src1');
      expect(source.episodeCount, 40);
      expect(source.readyEpisodeCount, 3);
      expect(source.lastJob!.status, IngestJobStatus.failed);
      expect(source.lastJob!.error, 'Feed returned 404');
      expect(source.createdAt, DateTime.utc(2026));
    });

    test('adds a source with its directory name and artwork', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/sources');
        expect(request.headers['content-type'], startsWith('application/json'));
        expect(jsonDecode(request.body), {
          'rssUrl': 'https://feeds.example/hardfork',
          'name': 'Hard Fork',
          'imageUrl': 'https://img.example/hf.jpg',
        });
        return http.Response(
            jsonEncode({
              'id': 'src9',
              'name': 'Hard Fork',
              'rssUrl': 'https://feeds.example/hardfork',
              'imageUrl': 'https://img.example/hf.jpg',
              'createdAt': '2026-01-01T00:00:00Z',
              'episodeCount': 0,
              'readyEpisodeCount': 0,
              'lastJob': {
                'status': 'queued',
                'error': null,
                'updatedAt': '2026-01-01T00:00:00Z',
              },
            }),
            201,
            headers: {'content-type': 'application/json'});
      }));
      final source = await api.addSource(
        rssUrl: 'https://feeds.example/hardfork',
        name: 'Hard Fork',
        imageUrl: 'https://img.example/hf.jpg',
      );
      expect(source.id, 'src9');
      expect(source.lastJob!.status, IngestJobStatus.queued);
    });

    test('sends position and history for an episode question', () async {
      final api = apiWith(MockClient((request) async {
        expect(jsonDecode(request.body), {
          'questionText': 'And what did she mean?',
          'topK': 6,
          'episodeId': 'ep1',
          'positionSec': 754.5,
          'history': [
            {'question': 'Who is speaking?', 'answer': 'The host.'},
          ],
        });
        return _jsonResponse({
          'answerText': 'She meant the budget.',
          'grounded': true,
          'citations': [
            {
              'segmentId': 'chapter:c1',
              'kind': 'chapter',
              'episodeId': 'ep1',
              'episodeTitle': 'A useful episode',
              'startSec': 700,
              'endSec': 800,
              'text': 'Budget talk',
              'score': 0.7,
            },
          ],
        });
      }));
      final answer = await api.askQuestion(
        questionText: 'And what did she mean?',
        episodeId: 'ep1',
        positionSec: 754.5,
        history: const [QaTurn(question: 'Who is speaking?', answer: 'The host.')],
      );
      expect(answer.citations.single.kind, CitationKind.chapter);
    });

    test('never sends a position without an episode', () async {
      final api = apiWith(MockClient((request) async {
        expect(jsonDecode(request.body), {'questionText': 'Q?', 'topK': 6});
        return _jsonResponse({'answerText': '', 'grounded': false});
      }));
      await api.askQuestion(questionText: 'Q?', positionSec: 12);
    });

    test('decodes JSON as UTF-8 when the charset is missing', () async {
      final api = apiWith(MockClient((request) async {
        return http.Response.bytes(
            utf8.encode(jsonEncode({'text': 'Hva sa værten?', 'durationMs': 1})),
            200,
            headers: {'content-type': 'application/json'});
      }));
      expect((await api.transcribeVoiceFile(audioFile.path)).text,
          'Hva sa værten?');
    });

    group('errors', () {
      Future<ApiException> errorFor(http.Response response) async {
        final api = apiWith(MockClient((_) async => response));
        try {
          await api.listSources();
        } on ApiException catch (error) {
          return error;
        }
        fail('Expected an ApiException');
      }

      test('parses the error body and request id', () async {
        final error = await errorFor(http.Response(
            jsonEncode({'error': 'internal', 'requestId': 'req-42'}), 500));
        expect(error.statusCode, 500);
        expect(error.serverMessage, 'internal');
        expect(error.requestId, 'req-42');
        expect(error.userMessage,
            'The server had a problem. Please try again in a moment.');
        expect(error.toString(), contains('req-42'));
      });

      test('429 tells how long to wait', () async {
        final error = await errorFor(http.Response(
            jsonEncode({'error': 'rate_limited'}), 429,
            headers: {'retry-after': '12'}));
        expect(error.retryAfter, const Duration(seconds: 12));
        expect(error.userMessage, 'Too many requests, try again in 12 s.');

        final withoutHeader = await errorFor(http.Response('', 429));
        expect(withoutHeader.userMessage,
            'Too many requests, try again in a moment.');
      });

      test('Retry-After may be an HTTP date', () {
        final now = DateTime.utc(2026, 1, 1, 12);
        expect(
            parseRetryAfter('Thu, 01 Jan 2026 12:00:30 GMT', now: now),
            const Duration(seconds: 30));
        expect(parseRetryAfter('soon', now: now), isNull);
        expect(parseRetryAfter(null), isNull);
      });

      test('409 explains that the episode is not ready', () async {
        final error = await errorFor(http.Response(
            jsonEncode({'error': 'episode_not_ready'}), 409));
        expect(error.userMessage, 'This episode isn’t ready for questions yet.');
      });

      test('401 points at the app key', () async {
        final error = await errorFor(
            http.Response(jsonEncode({'error': 'unauthorized'}), 401));
        expect(error.userMessage, contains('API_KEY'));
      });

      test('400 shows a readable server explanation only', () async {
        final readable = await errorFor(http.Response(
            jsonEncode({'error': 'Only http and https URLs are accepted'}),
            400));
        expect(readable.userMessage, 'Only http and https URLs are accepted.');
        final code = await errorFor(
            http.Response(jsonEncode({'error': 'invalid_body'}), 400));
        expect(code.userMessage, isNot(contains('invalid_body')));
      });

      test('describeError covers network failures and unknown errors', () {
        expect(describeError(const SocketException('down'), fallback: 'x'),
            contains('Couldn’t reach the server'));
        expect(
            describeError(
                TimeoutException('slow', const Duration(seconds: 1)),
                fallback: 'x'),
            contains('took too long'));
        expect(describeError(StateError('bug'), fallback: 'fallback'),
            'fallback');
        expect(
            describeError(ApiException(statusCode: 404), fallback: 'x'),
            contains('no longer available'));
      });
    });
  });
}
