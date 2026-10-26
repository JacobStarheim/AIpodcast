import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Remembers where the listener stopped in each episode.
abstract class PlaybackPositionStore {
  Future<Duration?> load(String episodeId);
  Future<void> save(String episodeId, Duration position);
  Future<void> clear(String episodeId);
}

/// Keeps positions for the lifetime of the app only.
class MemoryPlaybackPositionStore implements PlaybackPositionStore {
  final Map<String, Duration> positions = {};

  @override
  Future<Duration?> load(String episodeId) async => positions[episodeId];

  @override
  Future<void> save(String episodeId, Duration position) async =>
      positions[episodeId] = position;

  @override
  Future<void> clear(String episodeId) async => positions.remove(episodeId);
}

/// Stores positions across app restarts as one JSON map in shared
/// preferences, keeping the most recently saved [maxEntries] episodes.
class SharedPreferencesPositionStore implements PlaybackPositionStore {
  SharedPreferencesPositionStore({
    Future<SharedPreferences>? preferences,
    this.maxEntries = 200,
  }) : _preferences = preferences;

  static const storageKey = 'playback_positions_v1';

  final int maxEntries;
  Future<SharedPreferences>? _preferences;

  Future<SharedPreferences> get _prefs =>
      _preferences ??= SharedPreferences.getInstance();

  Map<String, int> _read(SharedPreferences preferences) {
    final raw = preferences.getString(storageKey);
    if (raw == null) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is int)
            entry.key as String: entry.value as int,
      };
    } on FormatException {
      return <String, int>{};
    }
  }

  @override
  Future<Duration?> load(String episodeId) async {
    final milliseconds = _read(await _prefs)[episodeId];
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  @override
  Future<void> save(String episodeId, Duration position) async {
    final preferences = await _prefs;
    // Re-insert so the map stays ordered from least to most recently saved.
    final positions = _read(preferences)
      ..remove(episodeId)
      ..[episodeId] = position.inMilliseconds;
    while (positions.length > maxEntries) {
      positions.remove(positions.keys.first);
    }
    await preferences.setString(storageKey, jsonEncode(positions));
  }

  @override
  Future<void> clear(String episodeId) async {
    final preferences = await _prefs;
    final positions = _read(preferences);
    if (positions.remove(episodeId) == null) return;
    await preferences.setString(storageKey, jsonEncode(positions));
  }
}
