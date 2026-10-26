import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'podcast_api.dart';

/// Podcasts in the library, the directory search and adding new feeds.
class SourcesController extends ChangeNotifier {
  SourcesController({
    required PodcastApi api,
    this.pollInterval = const Duration(seconds: 5),
    this.searchDebounce = const Duration(milliseconds: 400),
    this.onImportFinished,
  }) : _api = api;

  static const minimumQueryLength = 2;

  final PodcastApi _api;
  final Duration pollInterval;
  final Duration searchDebounce;

  /// Called when an import that was queued or processing has finished.
  final VoidCallback? onImportFinished;

  List<SourceSummary> items = const <SourceSummary>[];
  bool hasLoaded = false;
  bool isLoading = false;
  String? loadError;

  String searchQuery = '';
  List<PodcastSearchResult> results = const <PodcastSearchResult>[];
  bool isSearching = false;
  String? searchError;

  /// Sources added in this session, newest first.
  final List<String> recentlyAdded = <String>[];
  String? addError;

  final Set<String> _adding = <String>{};
  final Map<String, String> _addedFeeds = <String, String>{};
  Set<String> _importing = <String>{};
  Timer? _pollTimer;
  Timer? _searchTimer;
  int _loadGeneration = 0;
  int _searchGeneration = 0;
  bool _closed = false;

  int get readyEpisodeCount =>
      items.fold(0, (total, source) => total + source.readyEpisodeCount);

  bool get isImporting => items.any(_isImporting);

  bool isAdding(String feedUrl) => _adding.contains(feedUrl.trim());

  SourceSummary? sourceById(String id) {
    for (final source in items) {
      if (source.id == id) return source;
    }
    return null;
  }

  /// The library source for [feedUrl], when it was added or already exists.
  SourceSummary? sourceForFeed(String feedUrl) {
    final url = feedUrl.trim();
    final added = _addedFeeds[url];
    if (added != null) return sourceById(added);
    for (final source in items) {
      if (source.rssUrl == url) return source;
    }
    return null;
  }

  bool _isImporting(SourceSummary source) {
    final job = source.lastJob;
    if (job != null) return job.status.isInProgress;
    // Just added, and the import job is not visible yet.
    return recentlyAdded.contains(source.id) && source.episodeCount == 0;
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> load() async {
    if (_closed) return;
    final generation = ++_loadGeneration;
    isLoading = true;
    _notify();
    try {
      final sources = await _api.listSources();
      if (_closed || generation != _loadGeneration) return;
      loadError = null;
      _apply(sources);
    } catch (error) {
      if (_closed || generation != _loadGeneration) return;
      loadError = describeError(error,
          fallback: 'We couldn’t load your podcasts. Please try again.');
      // Keep following an import through a brief network problem.
      _schedulePoll();
    } finally {
      if (!_closed && generation == _loadGeneration) {
        isLoading = false;
        _notify();
      }
    }
  }

  void _apply(List<SourceSummary> sources) {
    items = List.unmodifiable(sources);
    hasLoaded = true;
    final importing = {
      for (final source in sources)
        if (_isImporting(source)) source.id
    };
    final finished = _importing.difference(importing).isNotEmpty;
    _importing = importing;
    _schedulePoll();
    if (finished) onImportFinished?.call();
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_closed || _importing.isEmpty) return;
    _pollTimer = Timer(pollInterval, () {
      _pollTimer = null;
      unawaited(load());
    });
  }

  /// Searches the podcast directory once typing pauses.
  void search(String query) {
    final text = query.trim();
    if (text == searchQuery) return;
    searchQuery = text;
    _searchTimer?.cancel();
    ++_searchGeneration;
    if (text.length < minimumQueryLength) {
      results = const <PodcastSearchResult>[];
      isSearching = false;
      searchError = null;
      _notify();
      return;
    }
    isSearching = true;
    searchError = null;
    _notify();
    _searchTimer = Timer(searchDebounce, () => unawaited(_runSearch(text)));
  }

  Future<void> _runSearch(String text) async {
    final generation = ++_searchGeneration;
    try {
      final found = await _api.searchPodcasts(text);
      if (_closed || generation != _searchGeneration) return;
      results = List.unmodifiable(found);
    } catch (error) {
      if (_closed || generation != _searchGeneration) return;
      results = const <PodcastSearchResult>[];
      searchError = describeError(error,
          fallback: 'Search isn’t available right now. Please try again.');
    } finally {
      if (!_closed && generation == _searchGeneration) {
        isSearching = false;
        _notify();
      }
    }
  }

  /// Adds the feed at [rssUrl] and follows its import. Returns the source, or
  /// null when it could not be added (see [addError]).
  Future<SourceSummary?> addPodcast({
    required String rssUrl,
    String? name,
    String? imageUrl,
  }) async {
    final url = rssUrl.trim();
    if (_closed || _adding.contains(url)) return null;
    if (!isValidFeedUrl(url)) {
      addError = 'Enter a feed link that starts with http:// or https://.';
      _notify();
      return null;
    }
    _adding.add(url);
    addError = null;
    _notify();
    try {
      final source =
          await _api.addSource(rssUrl: url, name: name, imageUrl: imageUrl);
      if (_closed) return null;
      _addedFeeds[url] = source.id;
      _addedFeeds[source.rssUrl] = source.id;
      recentlyAdded
        ..remove(source.id)
        ..insert(0, source.id);
      items = List.unmodifiable(
          [...items.where((item) => item.id != source.id), source]);
      if (_isImporting(source)) _importing = {..._importing, source.id};
      _schedulePoll();
      return source;
    } catch (error) {
      if (!_closed) {
        addError = describeError(error,
            fallback: 'We couldn’t add that podcast. Please try again.');
      }
      return null;
    } finally {
      _adding.remove(url);
      _notify();
    }
  }

  void dismissAddError() {
    addError = null;
    _notify();
  }

  void close() {
    _closed = true;
    _pollTimer?.cancel();
    _searchTimer?.cancel();
    ++_loadGeneration;
    ++_searchGeneration;
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}

bool isValidFeedUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}
