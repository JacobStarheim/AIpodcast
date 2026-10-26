import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class ConversationTurn {
  const ConversationTurn({
    required this.question,
    required this.response,
    this.positionSec,
  });

  final String question;
  final QaResponse response;

  /// Playback position the question referred to, if any.
  final double? positionSec;

  Map<String, Object> toJson() => {
        'question': question,
        'response': response.toJson(),
        if (positionSec != null) 'positionSec': positionSec!,
      };

  /// Returns null for data that is not a complete turn.
  static ConversationTurn? tryParse(Object? json) {
    if (json is! Map) return null;
    final question = json['question'];
    final response = json['response'];
    if (question is! String || question.isEmpty || response is! Map) {
      return null;
    }
    final position = json['positionSec'];
    return ConversationTurn(
      question: question,
      response: QaResponse.fromJson(response.cast<String, dynamic>()),
      positionSec:
          position is num && position.isFinite ? position.toDouble() : null,
    );
  }
}

/// Where a conversation belongs: the whole library or one episode.
String libraryConversationKey() => 'library';
String episodeConversationKey(String episodeId) => 'episode:$episodeId';

/// Keeps each conversation so it survives app restarts.
abstract class ConversationStore {
  Future<List<ConversationTurn>> load(String key);

  /// Replaces the stored conversation for [key]; an empty list removes it.
  Future<void> save(String key, List<ConversationTurn> turns);
  Future<void> clear(String key);
}

/// Keeps conversations for the lifetime of the app only.
class MemoryConversationStore implements ConversationStore {
  final Map<String, List<ConversationTurn>> conversations = {};

  @override
  Future<List<ConversationTurn>> load(String key) async =>
      List.of(conversations[key] ?? const <ConversationTurn>[]);

  @override
  Future<void> save(String key, List<ConversationTurn> turns) async {
    if (turns.isEmpty) {
      conversations.remove(key);
    } else {
      conversations[key] = List.of(turns);
    }
  }

  @override
  Future<void> clear(String key) async => conversations.remove(key);
}

/// Stores each conversation as JSON in shared preferences: the newest
/// [maxTurns] turns of the [maxConversations] most recently used
/// conversations. [namespace] keeps accounts on one device apart.
class SharedPreferencesConversationStore implements ConversationStore {
  SharedPreferencesConversationStore({
    this.namespace = 'default',
    this.maxTurns = 30,
    this.maxConversations = 20,
    Future<SharedPreferences>? preferences,
  }) : _preferences = preferences;

  static const prefix = 'conversation_v1';

  final String namespace;
  final int maxTurns;
  final int maxConversations;
  Future<SharedPreferences>? _preferences;
  Future<void> _queue = Future<void>.value();

  Future<SharedPreferences> get _prefs =>
      _preferences ??= SharedPreferences.getInstance();

  String get _indexKey => '$prefix/$namespace';
  String _turnsKey(String key) => '$prefix/$namespace/$key';

  /// Runs read-modify-write operations one after another.
  Future<T> _serially<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  List<String> _readIndex(SharedPreferences preferences) =>
      preferences.getStringList(_indexKey) ?? <String>[];

  @override
  Future<List<ConversationTurn>> load(String key) => _serially(() async {
        final raw = (await _prefs).getString(_turnsKey(key));
        if (raw == null) return <ConversationTurn>[];
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! List) return <ConversationTurn>[];
          final turns = decoded
              .map(ConversationTurn.tryParse)
              .whereType<ConversationTurn>();
          return _newest(turns.toList());
        } on FormatException {
          return <ConversationTurn>[];
        }
      });

  List<ConversationTurn> _newest(List<ConversationTurn> turns) =>
      turns.length > maxTurns ? turns.sublist(turns.length - maxTurns) : turns;

  @override
  Future<void> save(String key, List<ConversationTurn> turns) {
    if (turns.isEmpty) return clear(key);
    return _serially(() async {
      final preferences = await _prefs;
      await preferences.setString(_turnsKey(key),
          jsonEncode([for (final turn in _newest(turns)) turn.toJson()]));
      // Most recently saved last; drop the oldest conversations.
      final index = _readIndex(preferences)
        ..remove(key)
        ..add(key);
      while (index.length > maxConversations) {
        await preferences.remove(_turnsKey(index.removeAt(0)));
      }
      await preferences.setStringList(_indexKey, index);
    });
  }

  @override
  Future<void> clear(String key) => _serially(() async {
        final preferences = await _prefs;
        await preferences.remove(_turnsKey(key));
        final index = _readIndex(preferences);
        if (index.remove(key)) {
          await preferences.setStringList(_indexKey, index);
        }
      });
}
