part of '../podcast_controller.dart';

/// The episode list and its filters, the selected episode, transcription
/// requests (followed until done) and today's transcription allowance.
mixin _Library on _ControllerCore, _Playback, _Conversation {
  final Set<String> _transcriptionRequests = <String>{};
  final Set<String> _watchedEpisodes = <String>{};
  Timer? _queryDebounce;
  Timer? _pollTimer;
  List<SourceSummary> _seenSources = const <SourceSummary>[];
  int _listGeneration = 0;
  int _selectionGeneration = 0;
  int _usageGeneration = 0;

  List<EpisodeSummary> get episodes => List.unmodifiable(_episodes);
  String? nextCursor;
  bool isLoadingEpisodes = false;
  bool isLoadingMore = false;
  String libraryQuery = '';
  String? sourceFilter;
  bool onlyReady = false;

  /// Today's transcription minutes; null until loaded or when unavailable.
  TranscriptionUsage? usage;

  bool get hasMoreEpisodes => nextCursor != null;
  bool get hasLibraryFilter =>
      libraryQuery.isNotEmpty || sourceFilter != null || onlyReady;
  bool isTranscriptionRequested(String episodeId) =>
      _transcriptionRequests.contains(episodeId);

  void _onSourcesChanged() {
    if (identical(sources.items, _seenSources)) return;
    _seenSources = sources.items;
    _notify();
  }

  /// Loads the first page of episodes and the podcast list. Selects the
  /// first episode when none is selected yet.
  Future<void> loadInitialEpisodes() async {
    unawaited(sources.load());
    unawaited(refreshUsage());
    await _reloadEpisodes();
  }

  Future<void> _reloadEpisodes() async {
    if (_closed) return;
    final generation = ++_listGeneration;
    isLoadingEpisodes = true;
    isLoadingMore = false;
    _clearErrors((error) => error.kind == ErrorKind.library);
    _notify();
    try {
      final page = await _api.listEpisodes(
        limit: PodcastController.pageSize,
        sourceId: sourceFilter,
        query: libraryQuery,
        statuses: onlyReady ? {TranscriptionStatus.ready} : null,
      );
      if (_closed || generation != _listGeneration) return;
      _episodes
        ..clear()
        ..addAll(page.items);
      nextCursor = page.nextCursor;
      final selected = selectedEpisode;
      if (selected == null && !isSelectingEpisode) {
        if (_episodes.isNotEmpty) {
          await selectEpisode(_episodes.first.id, notify: false);
        }
      } else if (selected != null) {
        if (_episodes.isEmpty && !hasLibraryFilter && canSelectEpisode) {
          await _clearSelection();
        } else {
          unawaited(_refreshEpisode(selected.episode.id));
        }
      }
    } catch (error) {
      if (generation == _listGeneration) {
        _fail(ErrorKind.library, error,
            'We couldn’t load your episodes. Check your connection and try again.');
      }
    } finally {
      if (generation == _listGeneration) {
        isLoadingEpisodes = false;
        _notify();
      }
    }
  }

  Future<void> loadMoreEpisodes() async {
    if (_closed || isLoadingMore || isLoadingEpisodes || nextCursor == null) {
      return;
    }
    final generation = _listGeneration;
    isLoadingMore = true;
    _notify();
    try {
      final page = await _api.listEpisodes(
        cursor: nextCursor,
        limit: PodcastController.pageSize,
        sourceId: sourceFilter,
        query: libraryQuery,
        statuses: onlyReady ? {TranscriptionStatus.ready} : null,
      );
      if (_closed || generation != _listGeneration) return;
      final known = {for (final episode in _episodes) episode.id};
      _episodes.addAll(page.items.where((item) => !known.contains(item.id)));
      nextCursor = page.nextCursor;
    } catch (error) {
      if (generation == _listGeneration) {
        _fail(ErrorKind.library, error,
            'We couldn’t update your library. Check your connection and try again.');
      }
    } finally {
      if (generation == _listGeneration) {
        isLoadingMore = false;
        _notify();
      }
    }
  }

  /// Searches titles and descriptions on the server once typing pauses.
  void setLibraryQuery(String value) {
    final query = value.trim();
    if (query == libraryQuery) return;
    libraryQuery = query;
    _queryDebounce?.cancel();
    _queryDebounce = Timer(searchDebounce, () => unawaited(_reloadEpisodes()));
  }

  void setSourceFilter(String? sourceId) {
    if (sourceId == sourceFilter) return;
    sourceFilter = sourceId;
    _queryDebounce?.cancel();
    unawaited(_reloadEpisodes());
  }

  void setOnlyReady(bool value) {
    if (value == onlyReady) return;
    onlyReady = value;
    _queryDebounce?.cancel();
    unawaited(_reloadEpisodes());
  }

  Future<void> _clearSelection() async {
    ++_selectionGeneration;
    await stopAudio();
    selectedEpisode = null;
    isSelectingEpisode = false;
    _conversations[QuestionScope.episode]!.clear();
    if (scope == QuestionScope.episode) pendingQuestion = null;
    _setSelectedProgress(const PlaybackProgress());
  }

  /// Opens [episodeId] with its remembered position and its stored
  /// conversation.
  Future<void> selectEpisode(String episodeId, {bool notify = true}) async {
    if (!canSelectEpisode) return;
    final generation = ++_selectionGeneration;
    selectedEpisode = null;
    _conversations[QuestionScope.episode]!.clear();
    if (scope == QuestionScope.episode) pendingQuestion = null;
    _positionDismissed = false;
    error = null;
    isSelectingEpisode = true;
    _setSelectedProgress(const PlaybackProgress());
    if (notify) _notify();
    try {
      await stopAudio();
      final storedTurns = _loadEpisodeConversation(episodeId);
      final envelope = await _api.getEpisode(episodeId);
      if (_closed || generation != _selectionGeneration) return;
      final saved = await _loadSavedPosition(episodeId);
      if (_closed || generation != _selectionGeneration) return;
      final turns = await storedTurns;
      if (_closed || generation != _selectionGeneration) return;
      selectedEpisode = envelope;
      _episodeCache[episodeId] = envelope.episode;
      _conversations[QuestionScope.episode]!
        ..clear()
        ..addAll(turns);
      _setSelectedProgress(PlaybackProgress(
        position: saved ?? Duration.zero,
        duration: _durationOf(envelope.episode),
      ));
      if (envelope.transcriptionStatus.isInProgress) _watchEpisode(episodeId);
    } catch (error) {
      if (generation == _selectionGeneration) {
        _fail(ErrorKind.episode, error,
            'We couldn’t open that episode. Check your connection and try again.');
      }
    } finally {
      if (generation == _selectionGeneration) {
        isSelectingEpisode = false;
        if (notify) _notify();
      }
    }
  }

  // Transcription ------------------------------------------------------------

  /// Asks the server to transcribe [episodeId] and follows it until it is
  /// ready or failed.
  Future<void> requestTranscription(String episodeId) async {
    if (_closed || _transcriptionRequests.contains(episodeId)) return;
    _transcriptionRequests.add(episodeId);
    _clearErrors((error) => error.kind == ErrorKind.transcription);
    _notify();
    try {
      final result = await _api.transcribeEpisode(episodeId);
      if (_closed) return;
      _applySummary(result.episode);
      if (result.episode.transcriptionStatus.isInProgress) {
        _watchEpisode(episodeId);
      }
    } catch (error) {
      if (!_closed) {
        _fail(ErrorKind.transcription, error,
            'We couldn’t start the transcription. Please try again.');
      }
    } finally {
      _transcriptionRequests.remove(episodeId);
      _notify();
      unawaited(refreshUsage());
    }
  }

  /// Reloads today's transcription allowance. Failures keep the last known
  /// value; it is only a hint, the server enforces the limit.
  Future<void> refreshUsage() async {
    if (_closed) return;
    final generation = ++_usageGeneration;
    try {
      final fresh = await _api.getUsage();
      if (_closed || generation != _usageGeneration) return;
      usage = fresh;
      _notify();
    } catch (_) {
      // See above.
    }
  }

  void _watchEpisode(String episodeId) {
    _watchedEpisodes.add(episodeId);
    _schedulePoll();
  }

  void _schedulePoll() {
    if (_closed || _pollTimer != null || _watchedEpisodes.isEmpty) return;
    _pollTimer = Timer(pollInterval, () => unawaited(_pollEpisodes()));
  }

  Future<void> _pollEpisodes() async {
    var finished = false;
    for (final episodeId in _watchedEpisodes.toList()) {
      if (_closed) return;
      try {
        final envelope = await _api.getEpisode(episodeId);
        if (_closed) return;
        _applyDetail(envelope);
        if (!envelope.transcriptionStatus.isInProgress) {
          _watchedEpisodes.remove(episodeId);
          finished = true;
        }
      } on ApiException catch (error) {
        if (error.statusCode == 404) _watchedEpisodes.remove(episodeId);
      } catch (_) {
        // Keep waiting through a brief network problem.
      }
    }
    if (_closed) return;
    _pollTimer = null;
    _notify();
    _schedulePoll();
    if (finished) unawaited(refreshUsage());
  }

  Future<void> _refreshEpisode(String episodeId) async {
    try {
      final envelope = await _api.getEpisode(episodeId);
      if (_closed) return;
      _applyDetail(envelope);
      if (envelope.transcriptionStatus.isInProgress) _watchEpisode(episodeId);
      _notify();
    } catch (_) {
      // The list already refreshed; stale details are not worth an error.
    }
  }
}
