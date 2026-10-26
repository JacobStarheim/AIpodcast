import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:podcast_voice_ai/models.dart';
import 'package:podcast_voice_ai/podcast_api.dart';
import 'package:podcast_voice_ai/session_controller.dart';
import 'package:podcast_voice_ai/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const _ada = User(id: 'u1', email: 'ada@example.com', name: 'Ada Lovelace');

StoredSession _stored({String token = 'stored-token', DateTime? expiresAt}) =>
    StoredSession(
        token: token, user: _ada, expiresAt: expiresAt ?? DateTime.utc(2099));

SessionController _session({
  FakeAuthApi? api,
  SessionStore? store,
  String serviceToken = '',
}) =>
    SessionController(
      api: api ?? FakeAuthApi(),
      store: store ?? MemorySessionStore(),
      serviceToken: serviceToken,
      clock: () => DateTime.utc(2026, 10, 26),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionController', () {
    test('without a stored session or service key, sign-in is required',
        () async {
      final session = _session();
      expect(session.status, SessionStatus.restoring);
      await session.restore();
      expect(session.status, SessionStatus.signedOut);
      expect(session.token, isNull);
    });

    test('a service key skips signing in', () async {
      final api = FakeAuthApi();
      final session = _session(api: api, serviceToken: 'service-key');
      await session.restore();
      expect(session.status, SessionStatus.signedIn);
      expect(session.usesServiceToken, isTrue);
      expect(session.token, 'service-key');
      expect(session.user, isNull);
      expect(session.accountKey, 'service');
      expect(api.loginCalls + api.meCalls, 0);
    });

    test('signing in stores the token and uses it for requests', () async {
      final api = FakeAuthApi();
      final store = MemorySessionStore();
      final session = _session(api: api, store: store);
      await session.restore();
      final before = session.sessionId;

      expect(
          await session.signIn(
              email: ' ada@example.com ', password: FakeAuthApi.password),
          isTrue);
      expect(session.status, SessionStatus.signedIn);
      expect(session.token, 'token-1');
      expect(session.user!.name, 'Ada Lovelace');
      expect(session.accountKey, 'u1');
      expect(session.sessionId, isNot(before));
      expect(store.session!.token, 'token-1');
      expect(store.session!.user.email, 'ada@example.com');
    });

    test('a wrong password explains itself and stores nothing', () async {
      final store = MemorySessionStore();
      final session = _session(store: store);
      await session.restore();
      expect(await session.signIn(email: 'ada@example.com', password: 'nope'),
          isFalse);
      expect(session.status, SessionStatus.signedOut);
      expect(session.signInError,
          'That email and password don’t match an account.');
      expect(store.session, isNull);

      expect(await session.signIn(email: '', password: ''), isFalse);
      expect(session.signInError, 'Enter your email and password.');
    });

    test('too many sign-in attempts say how long to wait', () async {
      final api = FakeAuthApi()
        ..loginError = ApiException(
            statusCode: 429, retryAfter: const Duration(minutes: 15));
      final session = _session(api: api);
      await session.restore();
      await session.signIn(
          email: 'ada@example.com', password: FakeAuthApi.password);
      expect(session.signInError,
          'Too many sign-in attempts. Try again in 15 min.');
    });

    test('a stored session is restored and its account refreshed', () async {
      final api = FakeAuthApi()
        ..user = const User(id: 'u1', email: 'ada@example.com', name: 'Ada L.');
      final store = MemorySessionStore(_stored());
      final session = _session(api: api, store: store);
      await session.restore();
      expect(session.status, SessionStatus.signedIn);
      expect(session.token, 'stored-token');
      await Future<void>.delayed(Duration.zero);
      expect(api.meCalls, 1);
      expect(session.user!.name, 'Ada L.');
    });

    test('an expired stored session is removed', () async {
      final store =
          MemorySessionStore(_stored(expiresAt: DateTime.utc(2026, 10, 1)));
      final session = _session(store: store);
      await session.restore();
      expect(session.status, SessionStatus.signedOut);
      await Future<void>.delayed(Duration.zero);
      expect(store.session, isNull);
    });

    test('a revoked stored session signs out when the account is checked',
        () async {
      final api = FakeAuthApi()..meError = ApiException(statusCode: 401);
      final store = MemorySessionStore(_stored());
      final session = _session(api: api, store: store);
      await session.restore();
      await Future<void>.delayed(Duration.zero);
      expect(session.status, SessionStatus.signedOut);
      expect(session.notice, 'Your session has ended. Please sign in again.');
      expect(store.session, isNull);
    });

    test('offline at start keeps the stored session', () async {
      final api = FakeAuthApi()..meError = http.ClientException('offline');
      final session = _session(api: api, store: MemorySessionStore(_stored()));
      await session.restore();
      await Future<void>.delayed(Duration.zero);
      expect(session.status, SessionStatus.signedIn);
      expect(session.user!.email, 'ada@example.com');
    });

    test('signing out clears the token and revokes it on the server', () async {
      final api = FakeAuthApi();
      final store = MemorySessionStore(_stored());
      final session = _session(api: api, store: store);
      await session.restore();
      await session.signOut();
      expect(session.status, SessionStatus.signedOut);
      expect(session.token, isNull);
      expect(session.user, isNull);
      expect(session.notice, isNull);
      expect(store.session, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(api.loggedOut, ['stored-token']);
    });

    test('a 401 clears the token and asks to sign in again', () async {
      final store = MemorySessionStore(_stored());
      final session = _session(store: store);
      await session.restore();
      session.handleUnauthorized('stored-token');
      expect(session.status, SessionStatus.signedOut);
      expect(session.token, isNull);
      expect(session.notice, 'Your session has ended. Please sign in again.');
      await Future<void>.delayed(Duration.zero);
      expect(store.session, isNull);
    });

    test('a late 401 from an earlier session is ignored', () async {
      final session = _session(store: MemorySessionStore(_stored()));
      await session.restore();
      session.handleUnauthorized('an-older-token');
      session.handleUnauthorized(null);
      expect(session.status, SessionStatus.signedIn);
    });

    test('a rejected service key shows sign-in, which then works', () async {
      final session = _session(serviceToken: 'service-key');
      await session.restore();
      session.handleUnauthorized('service-key');
      expect(session.status, SessionStatus.signedOut);
      expect(session.token, isNull);
      expect(session.notice, contains('API key wasn’t accepted'));
      await session.signIn(
          email: 'ada@example.com', password: FakeAuthApi.password);
      expect(session.token, 'token-1');
      expect(session.usesServiceToken, isFalse);
    });

    test('signing out of the service key shows the sign-in screen', () async {
      final api = FakeAuthApi();
      final session = _session(api: api, serviceToken: 'service-key');
      await session.restore();
      await session.signOut();
      expect(session.status, SessionStatus.signedOut);
      expect(session.token, isNull);
      expect(api.loggedOut, isEmpty, reason: 'the service key is not revoked');
    });

    test('unreadable secure storage means signing in again', () async {
      final session = _session(store: _BrokenStore());
      await session.restore();
      expect(session.status, SessionStatus.signedOut);
    });
  });

  group('SecureSessionStore', () {
    test('keeps the session in secure storage, not shared preferences',
        () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final store = SecureSessionStore();
      expect(await store.read(), isNull);

      await store.write(_stored(token: 'secret-token'));
      final restored = await store.read();
      expect(restored!.token, 'secret-token');
      expect(restored.user.name, 'Ada Lovelace');
      expect(restored.expiresAt, DateTime.utc(2099));
      expect(
          await const FlutterSecureStorage()
              .read(key: SecureSessionStore.storageKey),
          contains('secret-token'));
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), isEmpty);

      await store.clear();
      expect(await store.read(), isNull);
    });

    test('ignores incomplete stored data', () async {
      FlutterSecureStorage.setMockInitialValues(
          {SecureSessionStore.storageKey: '{"token": ""}'});
      expect(await SecureSessionStore().read(), isNull);
      FlutterSecureStorage.setMockInitialValues(
          {SecureSessionStore.storageKey: 'not json'});
      expect(await SecureSessionStore().read(), isNull);
    });
  });

  group('HttpPodcastApi authentication', () {
    HttpPodcastApi apiWith(
      http.Client client, {
      String? Function()? token,
      void Function(String? token)? onUnauthorized,
    }) {
      addTearDown(client.close);
      return HttpPodcastApi(
        baseUrl: 'https://api.example',
        authToken: token,
        onUnauthorized: onUnauthorized,
        httpClient: client,
      );
    }

    test('signs in without a token and parses the session', () async {
      final api = apiWith(
        MockClient((request) async {
          expect(request.url.path, '/v1/auth/login');
          expect(request.headers.containsKey('Authorization'), isFalse);
          expect(jsonDecode(request.body),
              {'email': 'ada@example.com', 'password': 'pw'});
          return http.Response(
              jsonEncode({
                'token': 'tok',
                'expiresAt': '2026-11-25T00:00:00Z',
                'user': {
                  'id': 'u1',
                  'email': 'ada@example.com',
                  'name': 'Ada',
                  'role': 'admin',
                },
              }),
              200);
        }),
        token: () => 'stale-token',
      );
      final result = await api.login(email: 'ada@example.com', password: 'pw');
      expect(result.token, 'tok');
      expect(result.expiresAt, DateTime.utc(2026, 11, 25));
      expect(result.user.role, 'admin');
    });

    test('a wrong password is not an ended session', () async {
      var unauthorized = 0;
      final api = apiWith(
        MockClient((_) async => http.Response(
            jsonEncode({'error': 'invalid email or password'}), 401)),
        onUnauthorized: (_) => unauthorized++,
      );
      await expectLater(api.login(email: 'a@b.c', password: 'x'),
          throwsA(isA<ApiException>()));
      expect(unauthorized, 0);
    });

    test('sends the current token and reports a 401 with that token', () async {
      var token = 'first';
      final rejected = <String?>[];
      final seen = <String?>[];
      final api = apiWith(
        MockClient((request) async {
          seen.add(request.headers['Authorization']);
          return request.headers['Authorization'] == 'Bearer first'
              ? http.Response(jsonEncode({'items': <Object>[]}), 200)
              : http.Response(jsonEncode({'error': 'unauthorized'}), 401);
        }),
        token: () => token,
        onUnauthorized: rejected.add,
      );
      await api.listSources();
      token = 'second';
      await expectLater(api.listSources(), throwsA(isA<ApiException>()));
      expect(seen, ['Bearer first', 'Bearer second']);
      expect(rejected, ['second']);
    });

    test('a 401 on the answer stream is reported before streaming', () async {
      final rejected = <String?>[];
      final api = apiWith(
        MockClient((_) async =>
            http.Response(jsonEncode({'error': 'unauthorized'}), 401)),
        token: () => 'expired',
        onUnauthorized: rejected.add,
      );
      await expectLater(api.askQuestionStream(questionText: 'Q?').toList(),
          throwsA(isA<ApiException>()));
      expect(rejected, ['expired']);
    });

    test('logs out with the given token and reads the account', () async {
      final requests = <String>[];
      final api = apiWith(MockClient((request) async {
        requests.add(
            '${request.method} ${request.url.path} ${request.headers['Authorization']}');
        if (request.url.path == '/v1/auth/logout') {
          return http.Response('', 204);
        }
        return http.Response(
            jsonEncode({'id': 'u1', 'email': 'ada@example.com', 'name': 'Ada'}),
            200);
      }), token: () => 'current');
      await api.logout('old');
      final user = await api.me();
      expect(user.name, 'Ada');
      expect(requests,
          ['POST /v1/auth/logout Bearer old', 'GET /v1/me Bearer current']);
    });
  });
}

class _BrokenStore implements SessionStore {
  @override
  Future<StoredSession?> read() async => throw StateError('keystore broken');
  @override
  Future<void> write(StoredSession session) async {}
  @override
  Future<void> clear() async => throw StateError('keystore broken');
}
