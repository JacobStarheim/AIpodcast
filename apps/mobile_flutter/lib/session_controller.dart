import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'podcast_api.dart';
import 'session_store.dart';

enum SessionStatus { restoring, signedOut, signedIn }

/// Who is signed in, the bearer token for requests, signing in and out, and
/// what happens when the server stops accepting the token.
class SessionController extends ChangeNotifier {
  SessionController({
    required AuthApi api,
    required SessionStore store,
    this.serviceToken = '',
    DateTime Function()? clock,
  })  : _api = api,
        _store = store,
        _clock = clock ?? DateTime.now;

  /// A service token (`--dart-define=API_KEY`) that skips signing in.
  final String serviceToken;
  final AuthApi _api;
  final SessionStore _store;
  final DateTime Function() _clock;

  SessionStatus status = SessionStatus.restoring;

  /// The signed-in account; null while signed out or with the service token.
  User? user;
  bool isSigningIn = false;

  /// Why signing in failed, safe to show.
  String? signInError;

  /// Why the sign-in screen is showing, e.g. after the session expired.
  String? notice;

  String? _sessionToken;
  DateTime? _expiresAt;
  bool _serviceActive = false;
  int _sessionId = 0;
  Future<void> _storeOperations = Future<void>.value();
  bool _disposed = false;

  /// The bearer token for API requests, if any.
  String? get token =>
      _sessionToken ??
      (_serviceActive && serviceToken.isNotEmpty ? serviceToken : null);

  bool get isSignedIn => status == SessionStatus.signedIn;

  /// Signed in with the service token instead of an account.
  bool get usesServiceToken =>
      isSignedIn && _sessionToken == null && _serviceActive;

  /// Changes whenever someone signs in or out, so per-session state can be
  /// rebuilt.
  int get sessionId => _sessionId;

  /// Separates what is stored on the device (e.g. conversations) per account.
  String get accountKey =>
      user?.id ?? (usesServiceToken ? 'service' : 'signed-out');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Runs storage operations one after another, so a sign-out that is still
  /// clearing the store cannot delete the next session.
  Future<T> _serially<T>(Future<T> Function() operation) {
    final result = _storeOperations.then((_) => operation());
    _storeOperations = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Restores a stored, unexpired session, else uses the service token, else
  /// asks to sign in.
  Future<void> restore() async {
    StoredSession? stored;
    try {
      stored = await _serially(_store.read);
    } catch (_) {
      // Unreadable secure storage (e.g. restored from another device's
      // backup) only means signing in again.
      unawaited(_clearStore());
    }
    if (_disposed || status != SessionStatus.restoring) return;
    if (stored != null && stored.isExpiredAt(_clock())) {
      unawaited(_clearStore());
      stored = null;
    }
    if (stored != null) {
      _expiresAt = stored.expiresAt;
      _start(token: stored.token, user: stored.user);
      unawaited(_refreshUser());
      return;
    }
    if (serviceToken.isNotEmpty) {
      _serviceActive = true;
      _start(token: null, user: null);
      return;
    }
    status = SessionStatus.signedOut;
    _notify();
  }

  void _start({required String? token, required User? user}) {
    _sessionToken = token;
    this.user = user;
    status = SessionStatus.signedIn;
    notice = null;
    signInError = null;
    ++_sessionId;
    _notify();
  }

  /// Updates the stored name and email; a 401 signs out.
  Future<void> _refreshUser() async {
    final token = _sessionToken;
    if (token == null) return;
    try {
      final fresh = await _api.me();
      if (_disposed || _sessionToken != token) return;
      user = fresh;
      _notify();
      unawaited(_serially(() => _store.write(
              StoredSession(token: token, user: fresh, expiresAt: _expiresAt)))
          .catchError((Object _) {}));
    } on ApiException catch (error) {
      if (error.statusCode == 401) handleUnauthorized(token);
    } catch (_) {
      // Offline: keep the stored account until the server says otherwise.
    }
  }

  Future<bool> signIn({required String email, required String password}) async {
    if (isSigningIn || _disposed) return false;
    final address = email.trim();
    if (address.isEmpty || password.isEmpty) {
      signInError = 'Enter your email and password.';
      _notify();
      return false;
    }
    isSigningIn = true;
    signInError = null;
    _notify();
    try {
      final result = await _api.login(email: address, password: password);
      if (_disposed) return false;
      _expiresAt = result.expiresAt;
      try {
        await _serially(() => _store.write(StoredSession(
            token: result.token,
            user: result.user,
            expiresAt: result.expiresAt)));
      } catch (_) {
        // Still signed in for now; the next start asks to sign in again.
      }
      if (_disposed) return false;
      _serviceActive = false;
      _start(token: result.token, user: result.user);
      return true;
    } catch (error) {
      signInError = _signInMessage(error);
      return false;
    } finally {
      isSigningIn = false;
      _notify();
    }
  }

  String _signInMessage(Object error) {
    if (error is ApiException) {
      if (error.statusCode == 401) {
        return 'That email and password don’t match an account.';
      }
      if (error.statusCode == 429) {
        final wait = error.retryAfter;
        return wait == null
            ? 'Too many sign-in attempts. Please wait a moment and try again.'
            : 'Too many sign-in attempts. Try again in ${waitLabel(wait)}.';
      }
    }
    return describeError(error,
        fallback: 'Signing in didn’t work. Please try again.');
  }

  void dismissSignInError() {
    signInError = null;
    _notify();
  }

  /// Signs out on this device right away and revokes the token on the
  /// server in the background.
  Future<void> signOut() async {
    if (!isSignedIn) return;
    final token = _sessionToken;
    // Signing out of the service token shows the sign-in screen instead.
    _serviceActive = false;
    await _end(notice: null);
    if (token != null) {
      unawaited(_api.logout(token).catchError((Object _) {}));
    }
  }

  /// Called for a `401` on a request made with [rejectedToken]: clears the
  /// token and shows the sign-in screen. Responses to requests from an
  /// earlier session are ignored.
  void handleUnauthorized(String? rejectedToken) {
    if (!isSignedIn || rejectedToken != token) return;
    final service = usesServiceToken;
    _serviceActive = false;
    unawaited(_end(
        notice: service
            ? 'The app’s API key wasn’t accepted. Sign in with your account.'
            : 'Your session has ended. Please sign in again.'));
  }

  Future<void> _end({required String? notice}) async {
    _sessionToken = null;
    _expiresAt = null;
    user = null;
    status = SessionStatus.signedOut;
    this.notice = notice;
    signInError = null;
    ++_sessionId;
    _notify();
    await _clearStore();
  }

  Future<void> _clearStore() async {
    try {
      await _serially(_store.clear);
    } catch (_) {
      // Nothing more to do; the token is gone from memory.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
