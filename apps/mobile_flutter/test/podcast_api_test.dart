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

/// A server-sent event stream with one `data:` line per event.
String _sse(List<Object> events) =>
    events.map((event) => 'data: ${jsonEncode(event)}\n\n').join();

http.Response _sseResponse(List<Object> events) => http.Response.bytes(
      utf8.encode(_sse(events)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );

Map<String, Object> _done(Map<String, Object> response) =>
    {'type': 'done', 'response': response};

/// The final answer of an answer stream.
Future<QaResponse> _answerOf(Stream<QaStreamEvent> events) async =>
    (await events.toList()).whereType<QaDoneEvent>().single.response;

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

    test('streams a scoped question and maps grounded citations', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.method, 'POST');
        expect(
            request.url.toString(), 'https://api.example/v1/qa/answer/stream');
        expect(request.headers['content-type'], startsWith('application/json'));
        expect(request.headers['accept'], 'text/event-stream');
        expect(jsonDecode(request.body), {
          'questionText': 'Hva sa verten?',
          'episodeId': 'ep1',
          'topK': 3,
        });
        return _sseResponse([
          {'type': 'status', 'stage': 'searching'},
          {'type': 'status', 'stage': 'answering'},
          {'type': 'delta', 'text': 'Verten snakket '},
          {'type': 'delta', 'text': 'om arkitektur.'},
          _done({
            'answerText': 'Verten snakket om arkitektur.',
            'grounded': true,
            'citations': [
              {
                'segmentId': 'segment1',
                'episodeId': 'ep1',
                'episodeTitle': 'A useful episode',
                'startSec': 12.5,
                'endSec': 18,
                'playFromSec': 13.25,
                'text': 'Architecture matters.',
                'score': 0.9,
              },
            ],
          }),
        ]);
      }));

      final events = await api
          .askQuestionStream(
            questionText: 'Hva sa verten?',
            episodeId: 'ep1',
            topK: 3,
          )
          .toList();
      expect(events.whereType<QaStatusEvent>().map((event) => event.stage),
          [AnswerStage.searching, AnswerStage.answering]);
      expect(events.whereType<QaDeltaEvent>().map((event) => event.text).join(),
          'Verten snakket om arkitektur.');
      expect(events.last, isA<QaDoneEvent>());
      final answer = (events.last as QaDoneEvent).response;

      expect(answer.answerText, 'Verten snakket om arkitektur.');
      expect(answer.grounded, isTrue);
      expect(answer.refusalReason, isNull);
      final citation = answer.citations.single;
      expect(citation.segmentId, 'segment1');
      expect(citation.episodeId, 'ep1');
      expect(citation.episodeTitle, 'A useful episode');
      expect(citation.startSec, 12.5);
      expect(citation.endSec, 18.0);
      expect(citation.playFromSec, 13.25);
      expect(citation.text, 'Architecture matters.');
      expect(citation.score, 0.9);
    });

    test('omits absent episode scope and preserves refusal responses',
        () async {
      final api = apiWith(MockClient((request) async {
        expect(jsonDecode(request.body), {
          'questionText': 'Unanswerable question',
          'topK': 10,
        });
        return _sseResponse([
          {'type': 'status', 'stage': 'searching'},
          _done({
            'answerText': 'There is not enough evidence.',
            'grounded': false,
            'citations': <Object>[],
            'refusalReason': 'insufficient_retrieval_confidence',
          }),
        ]);
      }));

      for (final episodeId in <String?>[null, '']) {
        final answer = await _answerOf(api.askQuestionStream(
          questionText: 'Unanswerable question',
          episodeId: episodeId,
        ));
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
      'askQuestionStream': (api, _) =>
          api.askQuestionStream(questionText: 'Question?').toList(),
      'synthesize': (api, _) => api.synthesize('Answer.'),
      'transcribeVoiceFile': (api, path) => api.transcribeVoiceFile(path),
      'getUsage': (api, _) => api.getUsage(),
      'updateSource': (api, _) =>
          api.updateSource('src1', autoTranscribe: true),
      'me': (api, _) => api.me(),
    };

    for (final operation in operations.entries) {
      test('${operation.key} sends the bearer token', () async {
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
          'topK': 10,
          'episodeId': 'ep1',
          'positionSec': 754.5,
          'history': [
            {'question': 'Who is speaking?', 'answer': 'The host.'},
          ],
        });
        return _sseResponse([
          _done({
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
          }),
        ]);
      }));
      final answer = await _answerOf(api.askQuestionStream(
        questionText: 'And what did she mean?',
        episodeId: 'ep1',
        positionSec: 754.5,
        history: const [QaTurn(question: 'Who is speaking?', answer: 'The host.')],
      ));
      expect(answer.citations.single.kind, CitationKind.chapter);
    });

    test('never sends a position without an episode', () async {
      final api = apiWith(MockClient((request) async {
        expect(jsonDecode(request.body), {'questionText': 'Q?', 'topK': 10});
        return _sseResponse([
          _done({'answerText': '', 'grounded': false}),
        ]);
      }));
      await _answerOf(api.askQuestionStream(questionText: 'Q?', positionSec: 12));
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

    test('resolves relative playback links against the API base URL',
        () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/v1/episodes')) {
          return _jsonResponse({
            'items': [
              {
                ..._episodeJson,
                'playbackUrl': '/v1/media/episodes/ep1?exp=1&sig=a',
              },
              {..._episodeJson, 'id': 'ep2'},
            ],
          });
        }
        return _jsonResponse({
          'episode': {
            ..._episodeJson,
            'playbackUrl': 'https://cdn.example/ep1.mp3?sig=b',
          },
        });
      });
      addTearDown(client.close);
      final api = HttpPodcastApi(
          baseUrl: 'https://host.example/podcast-api/', httpClient: client);
      final items = (await api.listEpisodes()).items;
      expect(items.first.playbackUrl,
          'https://host.example/podcast-api/v1/media/episodes/ep1?exp=1&sig=a');
      expect(items.first.audioUrl, 'https://audio.example/ep1.mp3');
      expect(items.last.playbackUrl, 'https://audio.example/ep1.mp3',
          reason: 'without playbackUrl the publisher link is played');
      expect((await api.getEpisode('ep1')).episode.playbackUrl,
          'https://cdn.example/ep1.mp3?sig=b');
    });

    test('resolveApiUrl handles absolute, rooted and relative links', () {
      expect(resolveApiUrl('http://10.0.2.2:4000', '/v1/media/episodes/a?x=1'),
          'http://10.0.2.2:4000/v1/media/episodes/a?x=1');
      expect(resolveApiUrl('https://h.example/api/', '/v1/m'),
          'https://h.example/api/v1/m');
      expect(resolveApiUrl('https://h.example/api', 'v1/m'),
          'https://h.example/api/v1/m');
      expect(resolveApiUrl('https://h.example', '//cdn.example/a.mp3'),
          'https://cdn.example/a.mp3');
      expect(resolveApiUrl('https://h.example', 'https://other.example/a.mp3'),
          'https://other.example/a.mp3');
    });

    test('reads today\'s transcription usage', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), 'https://api.example/v1/usage');
        return _jsonResponse({
          'date': '2026-10-26',
          'usedMinutes': 42.5,
          'limitMinutes': 180,
          'remainingMinutes': 137.5,
        });
      }));
      final usage = await api.getUsage();
      expect(usage.date, '2026-10-26');
      expect(usage.usedMinutes, 42.5);
      expect(usage.limitMinutes, 180);
      expect(usage.remainingMinutes, 137.5);
      expect(usage.isUsedUp, isFalse);
    });

    test('turns automatic transcription on with a PATCH', () async {
      final api = apiWith(MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.toString(), 'https://api.example/v1/sources/src%201');
        expect(request.headers['content-type'], startsWith('application/json'));
        expect(jsonDecode(request.body), {'autoTranscribe': true});
        return _jsonResponse({
          'id': 'src 1',
          'name': 'Sample',
          'rssUrl': 'https://feeds.example/s',
          'autoTranscribe': true,
          'lastRefreshedAt': '2026-10-26T08:00:00Z',
          'episodeCount': 3,
          'readyEpisodeCount': 1,
          'lastJob': null,
        });
      }));
      final source = await api.updateSource('src 1', autoTranscribe: true);
      expect(source.autoTranscribe, isTrue);
      expect(source.lastRefreshedAt, DateTime.utc(2026, 10, 26, 8));
      expect(source.episodeCount, 3);
    });

    test('sends the selected episode with a voice question', () async {
      final api = apiWith(MockClient.streaming((request, bodyStream) async {
        final multipart = latin1.decode(await bodyStream.toBytes());
        expect(multipart,
            contains('content-disposition: form-data; name="episodeId"\r\n\r\nep 7\r\n'));
        expect(multipart, contains('name="audio"; filename="question.m4a"'));
        return http.StreamedResponse(
            Stream.value(utf8.encode('{"text":"Hvem er gjesten?"}')), 200);
      }));
      final result =
          await api.transcribeVoiceFile(audioFile.path, episodeId: 'ep 7');
      expect(result.text, 'Hvem er gjesten?');
    });

    test('a voice question without an episode has no episodeId field',
        () async {
      final api = apiWith(MockClient.streaming((request, bodyStream) async {
        final multipart = latin1.decode(await bodyStream.toBytes());
        expect(multipart, isNot(contains('name="episodeId"')));
        return http.StreamedResponse(Stream.value(utf8.encode('{"text":"Q"}')), 200);
      }));
      await api.transcribeVoiceFile(audioFile.path);
      await api.transcribeVoiceFile(audioFile.path, episodeId: '');
    });

    group('answer stream', () {
      Stream<List<int>> chunks(List<List<int>> parts) =>
          Stream.fromIterable(parts);

      List<List<int>> splitEvery(List<int> bytes, int size) => [
            for (var start = 0; start < bytes.length; start += size)
              bytes.sublist(start,
                  start + size > bytes.length ? bytes.length : start + size),
          ];

      test('events survive chunks that split lines, JSON and characters',
          () async {
        final body = utf8.encode(_sse([
          {'type': 'status', 'stage': 'searching'},
          {'type': 'status', 'stage': 'answering'},
          {'type': 'delta', 'text': 'Verten sa at «blåbær» '},
          {'type': 'delta', 'text': 'er gode.'},
          _done({'answerText': 'Verten sa at «blåbær» er gode.', 'grounded': true}),
        ]));
        for (final size in [1, 2, 3, 7, 64]) {
          final events = await parseAnswerStream(chunks(splitEvery(body, size)))
              .toList();
          expect(events, hasLength(5), reason: 'chunks of $size bytes');
          expect(
              events.whereType<QaDeltaEvent>().map((event) => event.text).join(),
              'Verten sa at «blåbær» er gode.');
          expect((events.last as QaDoneEvent).response.answerText,
              'Verten sa at «blåbær» er gode.');
        }
      });

      test('CRLF lines, comments, other fields and multi-line data', () async {
        const raw = ': keep-alive\r\n'
            'event: message\r\n'
            'id: 1\r\n'
            'data: {"type":"delta",\r\n'
            'data:"text":"Hi"}\r\n'
            '\r\n'
            'retry: 1000\r\n'
            '\r\n'
            'data: {"type":"done","response":{"answerText":"Hi","grounded":true}}';
        final data =
            await serverSentEventData(chunks([utf8.encode(raw)])).toList();
        expect(data, [
          '{"type":"delta",\n"text":"Hi"}',
          '{"type":"done","response":{"answerText":"Hi","grounded":true}}',
        ], reason: 'a final event without its blank line still counts');
        final events = await parseAnswerStream(chunks([utf8.encode(raw)])).toList();
        expect(events.map((event) => event.runtimeType),
            [QaDeltaEvent, QaDoneEvent]);
      });

      test('unknown and malformed events are skipped; the final one ends it',
          () async {
        final body = 'data: not json\n\n'
            'data: {"type":"ping"}\n\n'
            'data: {"type":"status","stage":"thinking"}\n\n'
            'data: [1,2]\n\n'
            '${_sse([
              {'type': 'error', 'error': 'model unavailable', 'requestId': 'r1'},
              {'type': 'delta', 'text': 'after the end'},
            ])}';
        final events =
            await parseAnswerStream(chunks([utf8.encode(body)])).toList();
        expect(events, hasLength(1));
        final error = events.single as QaErrorEvent;
        expect(error.error, 'model unavailable');
        expect(error.requestId, 'r1');
      });

      test('streams over HTTP as the chunks arrive', () async {
        final body = StreamController<List<int>>();
        final api = apiWith(MockClient.streaming((request, _) async =>
            http.StreamedResponse(body.stream, 200,
                headers: {'content-type': 'text/event-stream'})));
        final events = <QaStreamEvent>[];
        final done = api
            .askQuestionStream(questionText: 'Q?')
            .listen(events.add)
            .asFuture<void>();
        body.add(utf8.encode('data: {"type":"status","stage":"sea'));
        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);
        body.add(utf8.encode('rching"}\n\ndata: {"type":"delta","text":"A"}\n'));
        await Future<void>.delayed(Duration.zero);
        expect(events.map((event) => event.runtimeType), [QaStatusEvent]);
        body.add(utf8.encode('\n'));
        await Future<void>.delayed(Duration.zero);
        expect(events.map((event) => event.runtimeType),
            [QaStatusEvent, QaDeltaEvent]);
        body.add(utf8.encode(_sse([
          _done({'answerText': 'A', 'grounded': true})
        ])));
        await done;
        expect(events.last, isA<QaDoneEvent>());
        await body.close();
      });

      test('validation errors before streaming are normal API errors',
          () async {
        final api = apiWith(MockClient((_) async => http.Response(
            jsonEncode({'error': 'episode_not_ready'}), 409)));
        await expectLater(
            api.askQuestionStream(questionText: 'Q?', episodeId: 'ep1').toList(),
            throwsA(isA<ApiException>()
                .having((error) => error.statusCode, 'statusCode', 409)));
      });

      test('a stalled stream times out between chunks', () async {
        final body = StreamController<List<int>>();
        addTearDown(body.close);
        final api = apiWith(
          MockClient.streaming(
              (_, __) async => http.StreamedResponse(body.stream, 200)),
          requestTimeout: const Duration(milliseconds: 20),
        );
        body.add(utf8.encode(_sse([
          {'type': 'status', 'stage': 'searching'}
        ])));
        await expectLater(api.askQuestionStream(questionText: 'Q?').toList(),
            throwsA(isA<TimeoutException>()));
      });

      test('describeError explains a broken answer stream', () {
        expect(
            describeError(
                const AnswerStreamException(serverMessage: 'boom'),
                fallback: 'x'),
            'The answer couldn’t be finished. Please try again.');
      });
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

      test('401 asks to sign in again', () async {
        final error = await errorFor(
            http.Response(jsonEncode({'error': 'unauthorized'}), 401));
        expect(error.userMessage, 'Your session has ended. Please sign in again.');
      });

      test('a used-up daily transcription limit has its own message',
          () async {
        final error = await errorFor(http.Response(
            jsonEncode({
              'error': 'daily transcription limit reached',
              'code': 'transcription_budget_exceeded',
            }),
            429,
            headers: {'retry-after': '3600'}));
        expect(error.code, transcriptionBudgetExceeded);
        expect(error.isTranscriptionBudgetExceeded, isTrue);
        expect(error.userMessage, startsWith('Today’s transcription limit is used up'));
        expect(error.userMessage, isNot(contains('Too many requests')));
        expect(error.toString(), contains('transcription_budget_exceeded'));

        final other = await errorFor(http.Response(
            jsonEncode({'error': 'slow down', 'code': 'rate_limited'}), 429,
            headers: {'retry-after': '900'}));
        expect(other.isTranscriptionBudgetExceeded, isFalse);
        expect(other.userMessage, 'Too many requests, try again in 15 min.');
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
