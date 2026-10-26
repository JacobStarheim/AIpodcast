import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_voice_ai/models.dart';

void main() {
  test('every transcription status is parsed; unknown values are pending', () {
    expect(
        ['pending', 'queued', 'processing', 'ready', 'failed']
            .map(transcriptionStatusFromString),
        TranscriptionStatus.values);
    expect(transcriptionStatusFromString('archived'),
        TranscriptionStatus.pending);
    expect(transcriptionStatusFromString(null), TranscriptionStatus.pending);
    expect(TranscriptionStatus.queued.isInProgress, true);
    expect(TranscriptionStatus.processing.isInProgress, true);
    expect(TranscriptionStatus.failed.canRequestTranscription, true);
    expect(TranscriptionStatus.ready.canRequestTranscription, false);
  });

  test('episode summary tolerates missing and mistyped fields', () {
    final episode = EpisodeSummary.fromJson({
      'id': 'ep1',
      'title': 42,
      'durationSec': 61.6,
      'imageUrl': '',
      'transcriptionStatus': 'processing',
      'somethingNew': {'nested': true},
    });
    expect(episode.title, 'Untitled');
    expect(episode.sourceName, '');
    expect(episode.audioUrl, '');
    expect(episode.durationSec, 62);
    expect(episode.imageUrl, isNull);
    expect(episode.transcriptionError, isNull);
    expect(episode.transcriptionStatus, TranscriptionStatus.processing);
  });

  test('episode lists skip entries without an id or that are not objects', () {
    final page = EpisodePage.fromJson({
      'items': [
        {'id': 'ep1'},
        {'title': 'No id'},
        'garbage',
        null,
      ],
      'nextCursor': '',
    });
    expect(page.items.map((episode) => episode.id), ['ep1']);
    expect(page.nextCursor, isNull);
    expect(EpisodePage.fromJson({}).items, isEmpty);
  });

  test('episode detail reads summary, language and sorted chapters', () {
    final envelope = EpisodeDetailEnvelope.fromJson({
      'episode': {
        'id': 'ep1',
        'guid': 'g',
        'title': 'Title',
        'transcriptionStatus': 'ready',
        'language': 'nb',
        'summary': 'A short summary.',
        'chapters': [
          {
            'id': 'c2',
            'title': 'Second',
            'summary': 'Later',
            'startSec': 600,
            'endSec': 900
          },
          {'id': 'c1', 'title': 'First', 'startSec': 0, 'endSec': 600},
          'not a chapter',
        ],
      },
      'transcriptionStatus': 'ready',
    });
    final episode = envelope.episode;
    expect(episode.language, 'nb');
    expect(episode.summary, 'A short summary.');
    expect(episode.chapters.map((chapter) => chapter.id), ['c1', 'c2']);
    expect(episode.chapters.first.summary, '');
    expect(episode.chapters.last.startSec, 600);
  });

  test('episode detail without summary or chapters is still valid', () {
    final envelope = EpisodeDetailEnvelope.fromJson({
      'episode': {'id': 'ep1', 'chapters': null, 'summary': null},
    });
    expect(envelope.episode.chapters, isEmpty);
    expect(envelope.episode.summary, isNull);
    expect(envelope.transcriptionStatus, TranscriptionStatus.pending);
  });

  test('an episode response without an episode is a format error', () {
    expect(() => EpisodeDetailEnvelope.fromJson({'transcriptionStatus': 'ready'}),
        throwsFormatException);
  });

  test('citations read their kind and skip entries without an episode', () {
    final response = QaResponse.fromJson({
      'answerText': 'Answer',
      'grounded': 'yes',
      'citations': [
        {'segmentId': 's1', 'episodeId': 'ep1', 'kind': 'segment'},
        {'segmentId': 'chapter:c1', 'episodeId': 'ep1', 'kind': 'chapter'},
        {'segmentId': 's2', 'episodeId': 'ep1', 'kind': 'quote'},
        {'segmentId': 's3'},
      ],
    });
    expect(response.grounded, false, reason: 'only a JSON true counts');
    expect(response.citations.map((citation) => citation.kind), [
      CitationKind.segment,
      CitationKind.chapter,
      CitationKind.segment,
    ]);
    expect(response.citations.first.startSec, 0);
  });

  test('sources and their import job are parsed defensively', () {
    final sources = parseSourceList({
      'items': [
        {
          'id': 'src1',
          'rssUrl': 'https://feeds.example/a',
          'lastJob': {'status': 'paused'},
        },
        {'id': 'src2', 'name': 'Two', 'lastJob': null},
        {'name': 'No id'},
      ],
    });
    expect(sources.map((source) => source.id), ['src1', 'src2']);
    expect(sources.first.name, 'https://feeds.example/a');
    expect(sources.first.lastJob!.status, IngestJobStatus.unknown);
    expect(sources.first.lastJob!.status.isInProgress, false);
    expect(sources.last.lastJob, isNull);
    expect(sources.last.episodeCount, 0);
  });

  test('transcribe responses need an episode', () {
    expect(
        TranscribeEpisodeResult.fromJson({
          'jobId': 'j1',
          'episode': {'id': 'ep1', 'transcriptionStatus': 'queued'},
        }).episode.transcriptionStatus,
        TranscriptionStatus.queued);
    expect(() => TranscribeEpisodeResult.fromJson({'jobId': 'j1'}),
        throwsFormatException);
  });

  test('history turns serialize as question and answer', () {
    expect(const QaTurn(question: 'Q', answer: 'A').toJson(),
        {'question': 'Q', 'answer': 'A'});
  });
}
