import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_voice_ai/app_config.dart';
import 'package:podcast_voice_ai/conversation_store.dart';
import 'package:podcast_voice_ai/main.dart';
import 'package:podcast_voice_ai/models.dart';
import 'package:podcast_voice_ai/podcast_api.dart';
import 'package:podcast_voice_ai/podcast_controller.dart';
import 'package:podcast_voice_ai/presentation/library_sheet.dart';
import 'package:podcast_voice_ai/session_controller.dart';
import 'package:podcast_voice_ai/session_store.dart';

import 'fakes.dart';

const _ada = User(id: 'u1', email: 'ada@example.com', name: 'Ada Lovelace');

class _App {
  _App({
    FakeApi? api,
    FakeAuthApi? auth,
    SessionStore? store,
    String serviceToken = '',
  })  : api = api ?? FakeApi(),
        auth = auth ?? FakeAuthApi(),
        store = store ?? MemorySessionStore() {
    session = SessionController(
        api: this.auth, store: this.store, serviceToken: serviceToken);
  }

  final FakeApi api;
  final FakeAuthApi auth;
  final SessionStore store;
  late final SessionController session;
  final List<FakeAudioOutput> outputs = [];
  final List<PodcastController> controllers = [];

  FakeAudioOutput get audio => outputs.last;
  PodcastController get controller => controllers.last;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(PodcastVoiceApp(
      session: session,
      createController: (_) {
        final audio = FakeAudioOutput();
        outputs.add(audio);
        final controller = PodcastController(
          api: api,
          recorder: FakeRecorder(),
          audioOutput: audio,
        )..setReadAnswersAloud(false);
        controllers.add(controller);
        return controller;
      },
    ));
    await session.restore();
    await tester.pumpAndSettle();
  }
}

Future<void> _signIn(WidgetTester tester,
    {String email = 'ada@example.com',
    String password = FakeAuthApi.password}) async {
  await tester.enterText(find.byKey(const ValueKey('login-email')), email);
  await tester.enterText(
      find.byKey(const ValueKey('login-password')), password);
  final submit = find.byKey(const ValueKey('login-submit'));
  await tester.ensureVisible(submit);
  await tester.pumpAndSettle();
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

void main() {
  group('signing in', () {
    testWidgets('a debug build without API_KEY shows the sign-in screen',
        (tester) async {
      final app = _App(serviceToken: serviceApiKey);
      await app.pump(tester);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(PodcastHomePage), findsNothing);
      expect(app.controllers, isEmpty);
      await _expectAccessibleButton(
          tester, find.byKey(const ValueKey('login-submit')), 'Sign in');
    });

    testWidgets('a wrong password explains itself; the right one opens the app',
        (tester) async {
      final app = _App();
      await app.pump(tester);
      await _signIn(tester, password: 'wrong');
      expect(find.text('That email and password don’t match an account.'),
          findsOneWidget);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('login-password')))
              .controller!
              .text,
          isEmpty);

      await _signIn(tester);
      expect(find.byType(PodcastHomePage), findsOneWidget);
      expect(find.text('Episode ep1'), findsOneWidget);
      expect(app.session.token, 'token-1');
      expect((await app.store.read())!.token, 'token-1');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the password can be shown and hidden', (tester) async {
      final app = _App();
      await app.pump(tester);
      final field = find.byKey(const ValueKey('login-password'));
      bool obscured() => tester
          .widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)))
          .obscureText;
      expect(obscured(), isTrue);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(obscured(), isFalse);
      expect(find.byTooltip('Hide password'), findsOneWidget);
    });

    testWidgets('the account menu shows who is signed in and signs out',
        (tester) async {
      final app = _App(
          store: MemorySessionStore(StoredSession(
              token: 'stored', user: _ada, expiresAt: DateTime.utc(2099))));
      await app.pump(tester);
      expect(find.byType(PodcastHomePage), findsOneWidget);
      await app.controller.playSelectedEpisode();
      await tester.pumpAndSettle();

      final account = find.byKey(const ValueKey('account-menu'));
      await _expectAccessibleButton(tester, account, 'Account');
      await tester.tap(account);
      await tester.pumpAndSettle();
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('ada@example.com'), findsOneWidget);

      final signOut = find.byKey(const ValueKey('sign-out'));
      await _expectAccessibleButton(tester, signOut, 'Sign out');
      await tester.tap(signOut);
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(PodcastHomePage), findsNothing);
      expect(app.auth.loggedOut, ['stored']);
      expect(await app.store.read(), isNull);
      expect(app.audio.events, contains('stop'),
          reason: 'signing out stops playback');
      expect(tester.takeException(), isNull);

      await _signIn(tester);
      expect(app.controllers, hasLength(2),
          reason: 'the next session starts with a fresh controller');
    });

    testWidgets('a 401 anywhere returns to the sign-in screen', (tester) async {
      late final SessionController session;
      var rejectEpisodes = false;
      final client = MockClient((request) async {
        if (rejectEpisodes ||
            request.headers['Authorization'] != 'Bearer stored') {
          return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
        }
        if (request.url.path == '/v1/episodes') {
          return http.Response(
              jsonEncode({'items': <Object>[], 'nextCursor': null}), 200);
        }
        if (request.url.path == '/v1/sources') {
          return http.Response(jsonEncode({'items': <Object>[]}), 200);
        }
        if (request.url.path == '/v1/me') {
          return http.Response(jsonEncode(_ada.toJson()), 200);
        }
        return http.Response(
            jsonEncode({
              'date': '2026-10-26',
              'usedMinutes': 0,
              'limitMinutes': 180,
              'remainingMinutes': 180,
            }),
            200);
      });
      final api = HttpPodcastApi(
        baseUrl: 'https://api.example',
        httpClient: client,
        authToken: () => session.token,
        onUnauthorized: (token) => session.handleUnauthorized(token),
      );
      final store = MemorySessionStore(StoredSession(
          token: 'stored', user: _ada, expiresAt: DateTime.utc(2099)));
      session = SessionController(api: api, store: store);
      await tester.pumpWidget(PodcastVoiceApp(
        session: session,
        createController: (_) => PodcastController(
            api: api, recorder: FakeRecorder(), audioOutput: FakeAudioOutput()),
      ));
      await session.restore();
      await tester.pumpAndSettle();
      expect(find.byType(PodcastHomePage), findsOneWidget);

      rejectEpisodes = true;
      await tester.drag(find.byType(RefreshIndicator), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.text('Your session has ended. Please sign in again.'),
          findsOneWidget);
      expect(session.token, isNull);
      expect(await store.read(), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an ended session closes its open sheets', (tester) async {
      final app = _App(
          store: MemorySessionStore(StoredSession(
              token: 'stored', user: _ada, expiresAt: DateTime.utc(2099))));
      await app.pump(tester);
      await tester.tap(find.byTooltip('Browse episodes'));
      await tester.pumpAndSettle();
      expect(find.byType(LibrarySheet), findsOneWidget);
      app.session.handleUnauthorized('stored');
      await tester.pumpAndSettle();
      expect(find.byType(LibrarySheet), findsNothing);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a service key skips signing in', (tester) async {
      final app = _App(serviceToken: 'service-key');
      await app.pump(tester);
      expect(find.byType(LoginPage), findsNothing);
      expect(find.byType(PodcastHomePage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('account-menu')));
      await tester.pumpAndSettle();
      expect(find.text('This app’s API key'), findsOneWidget);
      expect(app.auth.loginCalls, 0);
    });

    testWidgets('sign-in fits a small screen with large text and a keyboard',
        (tester) async {
      _useSmallScreen(tester);
      final app = _App();
      await app.pump(tester);
      app.session.handleUnauthorized(null);
      final email = find.byKey(const ValueKey('login-email'));
      await tester.tap(email);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      await tester.enterText(email, 'ada@example.com');
      expect(email.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(email).dy, lessThanOrEqualTo(308));
      final password = find.byKey(const ValueKey('login-password'));
      await tester.ensureVisible(password);
      await tester.enterText(password, FakeAuthApi.password);
      final submit = find.byKey(const ValueKey('login-submit'));
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      expect(submit.hitTestable(), findsOneWidget);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.byType(PodcastHomePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the session-ended notice fits a small screen', (tester) async {
      _useSmallScreen(tester);
      final app = _App(
          store: MemorySessionStore(StoredSession(
              token: 'stored', user: _ada, expiresAt: DateTime.utc(2099))));
      await app.pump(tester);
      app.session.handleUnauthorized('stored');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('login-notice')), findsOneWidget);
      await _signIn(tester, password: 'wrong');
      await tester.ensureVisible(find.byKey(const ValueKey('login-error')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the account sheet fits a small screen', (tester) async {
      _useSmallScreen(tester);
      final app = _App(
          store: MemorySessionStore(StoredSession(
              token: 'stored',
              user: const User(
                  id: 'u1',
                  email: 'someone.with.a.long.address@example.com',
                  name: 'Someone With A Rather Long Name'),
              expiresAt: DateTime.utc(2099))));
      await app.pump(tester);
      await tester.tap(find.byKey(const ValueKey('account-menu')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('sign-out')));
      expect(tester.takeException(), isNull);
    });
  });

  group('streaming answers', () {
    testWidgets('show the stage, the text as it arrives, then the answer',
        (tester) async {
      final api = FakeApi()
        ..questionGate = Completer<void>()
        ..beforeDeltas = Completer<void>()
        ..beforeDone = Completer<void>();
      await _pumpHome(tester, api: api);
      await tester.enterText(
          find.byKey(const ValueKey('question-input')), 'What was discussed?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(find.text('Searching the episode…'), findsOneWidget);
      expect(find.byKey(const ValueKey('streaming-answer')), findsNothing);

      api.questionGate!.complete();
      await tester.pump();
      expect(find.text('Answering…'), findsOneWidget);

      api.beforeDeltas!.complete();
      await tester.pump();
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('streaming-answer')),
              matching: find.text('The host discussed architecture')),
          findsOneWidget);

      api.beforeDone!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('streaming-answer')), findsNothing);
      expect(find.text('Answering…'), findsNothing);
      expect(find.text('The host discussed architecture and citations.'),
          findsOneWidget);
      expect(find.text('From this episode'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('library questions search the library', (tester) async {
      final api = FakeApi()..questionGate = Completer<void>();
      final controller = await _pumpHome(tester, api: api);
      controller.setScope(QuestionScope.library);
      await tester.pump();
      await tester.enterText(
          find.byKey(const ValueKey('question-input')), 'Common themes?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(find.text('Searching your library…'), findsOneWidget);
      api.questionGate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('an error event shows a short message', (tester) async {
      final api = FakeApi()..streamError = 'upstream exploded';
      await _pumpHome(tester, api: api);
      await tester.enterText(
          find.byKey(const ValueKey('question-input')), 'What was discussed?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.text('The answer couldn’t be finished. Please try again.'),
          findsOneWidget);
      expect(find.textContaining('upstream'), findsNothing);
      expect(find.byKey(const ValueKey('streaming-answer')), findsNothing);
      expect(find.text('What was discussed?'), findsWidgets,
          reason: 'the question stays to try again');
    });

    testWidgets('a refusal after streamed text replaces it', (tester) async {
      final api = FakeApi()..refuseAfterDeltas = true;
      await _pumpHome(tester, api: api);
      await tester.enterText(
          find.byKey(const ValueKey('question-input')), 'Who is the captain?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.text('Not covered in this episode'), findsOneWidget);
      expect(
          find.text(
              'I do not have enough transcript evidence to answer that confidently.'),
          findsOneWidget,
          reason: 'the server writes refusals in the question’s language');
      expect(find.textContaining('The host discussed'), findsNothing);
      expect(find.textContaining('Listen from'), findsNothing);
    });

    testWidgets('streaming fits a small screen with large text',
        (tester) async {
      _useSmallScreen(tester);
      final api = FakeApi()..beforeDone = Completer<void>();
      final controller = await _pumpHome(tester, api: api);
      unawaited(controller.submitTypedQuestion('A long question about it'));
      await tester.pump();
      await tester.pump();
      await tester
          .ensureVisible(find.byKey(const ValueKey('streaming-answer')));
      expect(tester.takeException(), isNull);
      api.beforeDone!.complete();
      await tester.pumpAndSettle();
    });
  });

  testWidgets('Listen from plays from the start of the cited sentence',
      (tester) async {
    final api = FakeApi()..citationPlayFromSec = 117.5;
    final audio = FakeAudioOutput();
    await _pumpHome(tester, api: api, audio: audio);
    await tester.enterText(
        find.byKey(const ValueKey('question-input')), 'What was discussed?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    final listen = find.text('Listen from 1:57');
    await tester.ensureVisible(listen);
    await _expectAccessibleButton(tester, listen, 'Listen from 1:57');
    await tester.tap(listen);
    await tester.pumpAndSettle();
    expect(audio.lastEpisodeUrl, playbackUrlOf('ep1'));
    expect(audio.lastSeek, const Duration(milliseconds: 117500));
  });

  testWidgets('a stored conversation is back after a restart', (tester) async {
    final store = MemoryConversationStore()
      ..conversations['episode:ep1'] = [
        ConversationTurn(
          question: 'An earlier question',
          response: QaResponse(
              answerText: 'An earlier answer.',
              citations: const [],
              grounded: true),
        ),
      ];
    await _pumpHome(tester, conversations: store);
    expect(find.text('An earlier question'), findsOneWidget);
    expect(find.text('An earlier answer.'), findsOneWidget);
    final newConversation = find.byKey(const ValueKey('new-conversation'));
    await tester.ensureVisible(newConversation);
    await tester.tap(newConversation);
    await tester.pumpAndSettle();
    expect(find.text('An earlier question'), findsNothing);
    expect(store.conversations, isEmpty);
  });

  group('daily transcription limit', () {
    testWidgets('remaining minutes show next to Transcribe', (tester) async {
      final api = FakeApi()
        ..library = [demoEpisode('ep1', status: TranscriptionStatus.pending)];
      await _pumpHome(tester, api: api);
      expect(find.byKey(const ValueKey('transcribe-selected')), findsOneWidget);
      expect(find.text('2 h of 3 h transcription time left today.'),
          findsOneWidget);
    });

    testWidgets('a long episode says it needs more than what is left',
        (tester) async {
      final api = FakeApi()
        ..library = [demoEpisode('ep1', status: TranscriptionStatus.pending)]
        ..details['ep1'] = EpisodeDetail(
          id: 'ep1',
          sourceId: 'src1',
          sourceName: 'Demo',
          guid: 'g',
          title: 'A long one',
          description: '',
          publishedAt: DateTime.utc(2026),
          audioUrl: 'https://example.com/ep1.mp3',
          transcriptionStatus: TranscriptionStatus.pending,
          durationSec: 3 * 3600,
        );
      await _pumpHome(tester, api: api);
      expect(
          find.textContaining('This episode needs about 3 h.'), findsOneWidget);
    });

    testWidgets('a used-up limit has its own message', (tester) async {
      final api = FakeApi()
        ..library = [demoEpisode('ep1', status: TranscriptionStatus.pending)];
      await _pumpHome(tester, api: api);
      api
        ..transcribeError =
            ApiException(statusCode: 429, code: 'transcription_budget_exceeded')
        ..usage = TranscriptionUsage(
            date: '2026-10-26',
            usedMinutes: 180,
            limitMinutes: 180,
            remainingMinutes: 0);
      await tester.tap(find.byKey(const ValueKey('transcribe-selected')));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Today’s transcription limit is used up. Try again tomorrow.'),
          findsOneWidget);
      expect(find.textContaining('Too many requests'), findsNothing);
      expect(
          find.text('Today’s transcription limit is used up.'), findsOneWidget,
          reason: 'the refreshed usage says so too');
    });

    testWidgets('the library shows what is left today', (tester) async {
      await _pumpHome(tester);
      await tester.tap(find.byTooltip('Browse episodes'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-usage')), findsOneWidget);
      expect(find.text('2 h of 3 h transcription time left today.'),
          findsOneWidget);
    });
  });

  group('automatic transcription', () {
    testWidgets('filtering by a podcast shows its switch with an explanation',
        (tester) async {
      final api = FakeApi()
        ..sources = [
          demoSource('src1', 'Demo',
              lastRefreshedAt:
                  DateTime.now().subtract(const Duration(hours: 2))),
          demoSource('src2', 'Other'),
        ];
      await _pumpHome(tester, api: api);
      await tester.tap(find.byTooltip('Browse episodes'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('auto-transcribe-src1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('filter-source-src1')));
      await tester.pumpAndSettle();

      final toggle = find.byKey(const ValueKey('auto-transcribe-src1'));
      expect(toggle, findsOneWidget);
      expect(
          find.text(
              'New episodes are transcribed automatically, within the daily limit.'),
          findsOneWidget);
      expect(find.text('Checked for new episodes 2 h ago.'), findsOneWidget);
      await _expectSwitch(tester, toggle,
          label: 'Transcribe new episodes automatically', on: false);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
          api.sourceUpdates.single, (sourceId: 'src1', autoTranscribe: true));
      await _expectSwitch(tester, toggle,
          label: 'Transcribe new episodes automatically', on: true);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a refused change shows why and moves back', (tester) async {
      final api = FakeApi()..updateSourceError = ApiException(statusCode: 500);
      await _pumpHome(tester, api: api);
      await tester.tap(find.byTooltip('Browse episodes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-source-src1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-transcribe-src1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('auto-transcribe-error-src1')),
          findsOneWidget);
      expect(
          tester
              .widget<SwitchListTile>(
                  find.byKey(const ValueKey('auto-transcribe-src1')))
              .value,
          isFalse);
    });

    testWidgets('the podcast settings fit a small screen with large text',
        (tester) async {
      _useSmallScreen(tester);
      final api = FakeApi()
        ..sources = [demoSource('src1', 'A podcast with a rather long name')];
      final controller = await _pumpHome(tester, api: api);
      controller.setSourceFilter('src1');
      await tester.tap(find.byTooltip('Browse episodes'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('auto-transcribe-src1')), 100,
          scrollable: find
              .descendant(
                  of: find.byType(LibrarySheet),
                  matching: find.byType(Scrollable))
              .first);
      expect(tester.takeException(), isNull);
    });
  });
}

Future<PodcastController> _pumpHome(
  WidgetTester tester, {
  FakeApi? api,
  FakeAudioOutput? audio,
  ConversationStore? conversations,
}) async {
  final controller = PodcastController(
    api: api ?? FakeApi(),
    recorder: FakeRecorder(),
    audioOutput: audio ?? FakeAudioOutput(),
    conversationStore: conversations,
  )..setReadAnswersAloud(false);
  await tester.pumpWidget(PodcastVoiceApp(controller: controller));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _expectAccessibleButton(
    WidgetTester tester, Finder finder, String label) async {
  final semantics = tester.ensureSemantics();
  try {
    await tester.pump();
    final data = tester.getSemantics(finder).getSemanticsData();
    // Icon buttons are named by their tooltip.
    expect('${data.label} ${data.tooltip}', contains(label));
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
  } finally {
    semantics.dispose();
  }
}

Future<void> _expectSwitch(WidgetTester tester, Finder finder,
    {required String label, required bool on}) async {
  final semantics = tester.ensureSemantics();
  try {
    await tester.pump();
    final data = tester.getSemantics(finder).getSemanticsData();
    expect(data.label, contains(label));
    expect(data.flagsCollection.isToggled,
        on ? Tristate.isTrue : Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
  } finally {
    semantics.dispose();
  }
}

void _useSmallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.8;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.view.resetViewInsets);
}
