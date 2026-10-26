import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

/// A signed-in session as kept on the device.
class StoredSession {
  const StoredSession(
      {required this.token, required this.user, this.expiresAt});

  final String token;
  final User user;
  final DateTime? expiresAt;

  bool isExpiredAt(DateTime now) {
    final expires = expiresAt;
    return expires != null && !expires.isAfter(now);
  }

  Map<String, Object?> toJson() => {
        'token': token,
        'user': user.toJson(),
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
      };

  /// Returns null for data that is not a complete session.
  static StoredSession? tryParse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final token = json['token'];
      final user = json['user'];
      if (token is! String || token.isEmpty || user is! Map) return null;
      final parsed = User.tryParse(user.cast<String, dynamic>());
      if (parsed == null) return null;
      final expires = json['expiresAt'];
      return StoredSession(
        token: token,
        user: parsed,
        expiresAt: expires is String ? DateTime.tryParse(expires) : null,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Where the session token lives between app starts.
abstract class SessionStore {
  Future<StoredSession?> read();
  Future<void> write(StoredSession session);
  Future<void> clear();
}

/// Keeps the session in the iOS Keychain or the Android Keystore-backed
/// storage of flutter_secure_storage, never in shared preferences.
class SecureSessionStore implements SessionStore {
  SecureSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // Readable after the first unlock, so a locked phone that keeps
              // playing in the background can still restore the session.
              iOptions: IOSOptions(
                  accessibility:
                      KeychainAccessibility.first_unlock_this_device),
            );

  static const storageKey = 'session_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<StoredSession?> read() async {
    final raw = await _storage.read(key: storageKey);
    return raw == null ? null : StoredSession.tryParse(raw);
  }

  @override
  Future<void> write(StoredSession session) =>
      _storage.write(key: storageKey, value: jsonEncode(session.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: storageKey);
}

/// Keeps the session for the lifetime of the app only.
class MemorySessionStore implements SessionStore {
  MemorySessionStore([this.session]);

  StoredSession? session;

  @override
  Future<StoredSession?> read() async => session;

  @override
  Future<void> write(StoredSession session) async => this.session = session;

  @override
  Future<void> clear() async => session = null;
}
