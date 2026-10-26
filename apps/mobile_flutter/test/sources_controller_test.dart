import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_voice_ai/models.dart';
import 'package:podcast_voice_ai/podcast_api.dart';
import 'package:podcast_voice_ai/podcast_controller.dart';
import 'package:podcast_voice_ai/sources_controller.dart';

import 'fakes.dart';

PodcastSearchResult result(String title) => PodcastSearchResult(
      title: title,
      author: 'Host of $title',
      feedUrl: 'https://feeds.example/${title.toLowerCase()}.xml',
      imageUrl: 'https://img.example/${title.toLowerCase()}.jpg',
    );

void main() {
  test('directory search is debounced and ignores very short queries', () {
    fakeAsync((async) {
      final api = FakeApi()..searchResults = [result('History'), result('Art')];
      final sources = SourcesController(api: api);
      sources.search('H');
      async.elapse(const Duration(seconds: 1));
      expect(api.searchQueries, isEmpty);
      expect(sources.isSearching, false);

      sources.search('Hi');
      sources.search('Hist');
      sources.search('History ');
      expect(sources.isSearching, true);
      async.elapse(const Duration(milliseconds: 399));
      expect(api.searchQueries, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(api.searchQueries, ['History']);
      expect(sources.isSearching, false);
      expect(sources.results.single.title, 'History');
      sources.close();
    });
  });

  test(
      'adding a podcast follows its import every 5 s and refreshes episodes when it completes',
      () {
    fakeAsync((async) {
      final api = FakeApi()..searchResults = [result('History')];
      final controller = PodcastController(
          api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
      controller.loadInitialEpisodes();
      async.flushMicrotasks();
      final sources = controller.sources;
      final listCalls = api.listCalls;
      final sourceCalls = api.sourcesCalls;

      final added = demoSource('src-new', 'History',
          rssUrl: 'https://feeds.example/history.xml',
          job: IngestJobStatus.processing,
          episodes: 0,
          ready: 0);
      api.sourceSnapshots.addAll([
        [demoSource('src1', 'Demo'), added],
        [
          demoSource('src1', 'Demo'),
          demoSource('src-new', 'History',
              rssUrl: 'https://feeds.example/history.xml', episodes: 25),
        ],
      ]);

      final podcast = result('History');
      sources.addPodcast(
          rssUrl: podcast.feedUrl,
          name: podcast.title,
          imageUrl: podcast.imageUrl);
      expect(sources.isAdding(podcast.feedUrl), true);
      async.flushMicrotasks();
      expect(api.addRequests.single, (
        rssUrl: 'https://feeds.example/history.xml',
        name: 'History',
        imageUrl: 'https://img.example/history.jpg',
      ));
      final source = sources.sourceForFeed(podcast.feedUrl)!;
      expect(source.lastJob!.status, IngestJobStatus.queued);
      expect(sources.recentlyAdded, ['src-new']);
      expect(sources.isImporting, true);

      async.elapse(const Duration(seconds: 5));
      expect(api.sourcesCalls, sourceCalls + 1);
      expect(sources.sourceById('src-new')!.lastJob!.status,
          IngestJobStatus.processing);
      expect(api.listCalls, listCalls);

      async.elapse(const Duration(seconds: 5));
      expect(api.sourcesCalls, sourceCalls + 2);
      expect(sources.isImporting, false);
      expect(sources.sourceById('src-new')!.episodeCount, 25);
      expect(api.listCalls, listCalls + 1, reason: 'episode list refreshed');

      async.elapse(const Duration(minutes: 1));
      expect(api.sourcesCalls, sourceCalls + 2, reason: 'polling stopped');
      controller.close();
    });
  });

  test('a failed import keeps its error and stops polling', () {
    fakeAsync((async) {
      final api = FakeApi();
      api.sourceSnapshots.add([
        demoSource('src-new', 'Broken',
            rssUrl: 'https://feeds.example/broken.xml',
            job: IngestJobStatus.failed,
            jobError: 'Feed returned 404',
            episodes: 0),
      ]);
      final sources = SourcesController(api: api);
      sources.addPodcast(rssUrl: 'https://feeds.example/broken.xml');
      async.elapse(const Duration(seconds: 5));
      final source = sources.sourceById('src-new')!;
      expect(source.lastJob!.status, IngestJobStatus.failed);
      expect(source.lastJob!.error, 'Feed returned 404');
      expect(async.pendingTimers, isEmpty);
      sources.close();
    });
  });

  test('an invalid feed link is rejected without a request', () async {
    final api = FakeApi();
    final sources = SourcesController(api: api);
    expect(await sources.addPodcast(rssUrl: 'feeds.example/x.xml'), isNull);
    expect(await sources.addPodcast(rssUrl: 'ftp://feeds.example/x.xml'),
        isNull);
    expect(api.addRequests, isEmpty);
    expect(sources.addError, contains('http://'));
    sources.dismissAddError();
    expect(sources.addError, isNull);
    expect(isValidFeedUrl(' https://feeds.example/x.xml '), true);
  });

  test('add errors show a short message', () async {
    final api = FakeApi()
      ..addError = ApiException(
          statusCode: 429, retryAfter: const Duration(minutes: 30));
    final sources = SourcesController(api: api);
    expect(await sources.addPodcast(rssUrl: 'https://feeds.example/x.xml'),
        isNull);
    expect(sources.addError, 'Too many requests, try again in 1800 s.');
    expect(sources.isAdding('https://feeds.example/x.xml'), false);
  });

  test('ready episode counts across sources enable library questions',
      () async {
    final api = FakeApi()
      ..library = [demoEpisode('a', status: TranscriptionStatus.pending)]
      ..sources = [
        demoSource('src1', 'Demo', ready: 0),
        demoSource('src2', 'Other', ready: 2),
      ];
    final controller = PodcastController(
        api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput());
    await controller.loadInitialEpisodes();
    await Future<void>.delayed(Duration.zero);
    expect(controller.sources.readyEpisodeCount, 2);
    controller.setScope(QuestionScope.library);
    expect(controller.canAskQuestion, true);
    await controller.close();
  });
}
