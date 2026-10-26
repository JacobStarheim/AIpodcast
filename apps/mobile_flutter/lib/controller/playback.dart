part of '../podcast_controller.dart';

const _playbackFailedMessage =
    'This audio couldn’t play. Check your connection and try again.';
const _saveEvery = Duration(seconds: 5);

/// The episode player: play, pause, seek, citations, remembered positions,
/// lock screen commands and renewing expired playback links.
mixin _Playback on _ControllerCore {
  PlayerStatus playerStatus = PlayerStatus.stopped;
  EpisodeDetail? _loadedEpisode;

  /// The link the player loaded, which may be older than the episode's
  /// current playbackUrl.
  String? _loadedUrl;

  /// The loaded link came from renewing a failed one; it is not renewed
  /// again.
  bool _loadedAfterRefresh = false;
  Duration _loadedPosition = Duration.zero;
  Duration? _loadedDuration;
  Duration _lastSavedPosition = Duration.zero;
  bool _sawPlaying = false;
  String? activeCitationId;
  int _playbackGeneration = 0;
  StreamSubscription<EpisodeProgress>? _progressSubscription;
  StreamSubscription<RemoteCommand>? _remoteSubscription;

  bool get isAudioPlaying =>
      playerStatus == PlayerStatus.playing ||
      playerStatus == PlayerStatus.loading;

  /// The episode in the player, which may differ from the selected one
  /// after playing a citation from another episode.
  EpisodeDetail? get nowPlaying =>
      playerStatus == PlayerStatus.stopped ? null : _loadedEpisode;
  bool get isSelectedLoaded =>
      _loadedEpisode != null &&
      _loadedEpisode!.id == selectedEpisode?.episode.id;
  bool get isPlayingEpisode => isSelectedLoaded && isAudioPlaying;
  bool get isPlayingCitation => activeCitationId != null && isAudioPlaying;

  void _listenToPlayer() {
    _progressSubscription = _audioOutput.episodeProgress
        .listen(_onProgress, onError: _onPlaybackError);
    _remoteSubscription = _audioOutput.remoteCommands.listen(_onRemoteCommand);
  }

  Future<void> _stopListeningToPlayer() async {
    final progress = _progressSubscription;
    final remote = _remoteSubscription;
    _progressSubscription = null;
    _remoteSubscription = null;
    await progress?.cancel();
    await remote?.cancel();
  }

  Future<void> togglePlayback() =>
      isPlayingEpisode ? pausePlayback() : playSelectedEpisode();

  /// Plays the selected episode from where the listener left off.
  Future<void> playSelectedEpisode() async {
    final episode = selectedEpisode?.episode;
    if (episode == null || !canControlPlayback) return;
    final progress = selectedProgress.value;
    var from = progress.position;
    final duration = progress.duration;
    if (duration != null &&
        from >= duration - PodcastController.finishedMargin) {
      from = Duration.zero;
    }
    await _startPlayback(episode, from: from);
  }

  /// Plays the selected episode from [position], e.g. a chapter start.
  Future<void> playSelectedEpisodeFrom(Duration position) async {
    final episode = selectedEpisode?.episode;
    if (episode == null || !canControlPlayback) return;
    await _startPlayback(episode,
        from: position.isNegative ? Duration.zero : position);
  }

  /// Pauses or resumes the episode in the player, whichever it is.
  Future<void> toggleNowPlaying() async {
    final episode = nowPlaying;
    if (episode == null || !canControlPlayback) return;
    if (isAudioPlaying) {
      await pausePlayback();
    } else {
      await _startPlayback(episode, from: _loadedPosition);
    }
  }

  Future<void> pausePlayback() async {
    if (!isAudioPlaying || !canControlPlayback) return;
    await _pausePlayer();
    _notify();
  }

  Future<Duration> _pausePlayer() async {
    ++_playbackGeneration;
    final wasLoading = playerStatus == PlayerStatus.loading;
    playerStatus = PlayerStatus.paused;
    activeCitationId = null;
    _notify();
    try {
      final position = await _audioOutput.pauseEpisode();
      // While loading, the player has not reached the requested start yet.
      if (!wasLoading) _updateLoadedPosition(position);
    } catch (_) {
      // Keep the last reported position. Should the player keep going, its
      // progress updates switch the status back to playing.
    }
    unawaited(_saveLoadedPosition(force: true));
    return _loadedPosition;
  }

  /// Moves the selected episode to [position]. Without loaded audio this sets
  /// where playback will start.
  Future<void> seekSelectedEpisode(Duration position) async {
    final episode = selectedEpisode?.episode;
    if (episode == null || !canControlPlayback) return;
    final duration = selectedProgress.value.duration;
    var target = position.isNegative ? Duration.zero : position;
    if (duration != null && target > duration) target = duration;
    _positionDismissed = false;
    _setSelectedProgress(
        PlaybackProgress(position: target, duration: duration));
    if (isSelectedLoaded && playerStatus == PlayerStatus.loading) {
      await _startPlayback(episode, from: target);
      return;
    }
    if (isSelectedLoaded && playerStatus != PlayerStatus.stopped) {
      activeCitationId = null;
      _loadedPosition = target;
      try {
        await _audioOutput.seekEpisode(target);
      } catch (error) {
        _fail(ErrorKind.playback, error, _playbackFailedMessage);
      }
      unawaited(_saveLoadedPosition(force: true));
    } else {
      unawaited(_storePosition(episode.id, target, duration));
    }
    _notify();
  }

  /// Moves the episode in the player to [position]; the selected episode
  /// when nothing else is loaded. Used by lock screen controls.
  Future<void> seekNowPlaying(Duration position) async {
    final episode = nowPlaying;
    if (episode == null || episode.id == selectedEpisode?.episode.id) {
      await seekSelectedEpisode(position);
      return;
    }
    if (!canControlPlayback) return;
    final duration = _loadedDuration;
    var target = position.isNegative ? Duration.zero : position;
    if (duration != null && target > duration) target = duration;
    if (playerStatus == PlayerStatus.loading) {
      await _startPlayback(episode, from: target);
      return;
    }
    activeCitationId = null;
    _loadedPosition = target;
    try {
      await _audioOutput.seekEpisode(target);
    } catch (error) {
      _fail(ErrorKind.playback, error, _playbackFailedMessage);
    }
    unawaited(_saveLoadedPosition(force: true));
    _notify();
  }

  /// Plays [citation] from the start of the cited sentence.
  Future<void> playCitation(Citation citation) async {
    if (!canControlPlayback) return;
    final seconds = citation.playFromSec.isFinite && citation.playFromSec > 0
        ? citation.playFromSec
        : 0.0;
    final from = Duration(milliseconds: (seconds * 1000).round());
    final known = selectedEpisode?.episode.id == citation.episodeId
        ? selectedEpisode!.episode
        : _episodeCache[citation.episodeId];
    if (known != null) {
      await _startPlayback(known, from: from, citationId: citation.segmentId);
      return;
    }
    final generation = ++_playbackGeneration;
    activeCitationId = citation.segmentId;
    _clearErrors((error) => error.kind == ErrorKind.playback);
    _notify();
    try {
      final envelope = await _api.getEpisode(citation.episodeId);
      if (_closed || generation != _playbackGeneration) return;
      _episodeCache[citation.episodeId] = envelope.episode;
      await _startPlayback(envelope.episode,
          from: from, citationId: citation.segmentId);
    } catch (error) {
      if (!_closed && generation == _playbackGeneration) {
        activeCitationId = null;
        _fail(ErrorKind.playback, error, _playbackFailedMessage);
        _notify();
      }
    }
  }

  EpisodeMedia _mediaFor(EpisodeDetail episode) => EpisodeMedia(
        id: episode.id,
        title: episode.title,
        podcast: episode.sourceName,
        artworkUrl: episode.imageUrl,
        duration: _durationOf(episode),
      );

  /// Plays [episode] from [from]. A link that fails to load is renewed once
  /// (signed links expire) unless [renewed] says this already is the renewed
  /// one.
  Future<void> _startPlayback(EpisodeDetail episode,
      {required Duration from,
      String? citationId,
      bool renewed = false}) async {
    if (_closed) return;
    // Keep the link the player already has for this episode, so a resume
    // does not reload the audio after the episode details were refreshed.
    final url = !renewed &&
            _loadedEpisode?.id == episode.id &&
            _loadedUrl != null &&
            playerStatus != PlayerStatus.stopped
        ? _loadedUrl!
        : episode.playbackUrl;
    if (url.isEmpty) {
      error = const AppError(ErrorKind.playback, _playbackFailedMessage);
      _notify();
      return;
    }
    final generation = ++_playbackGeneration;
    if (voiceState == VoiceState.speaking) {
      // Playing the episode interrupts the spoken answer.
      ++_questionGeneration;
      isPreparingSpeech = false;
      voiceState = VoiceState.idle;
      _resumeAfterQuestion = false;
      _capturedPosition = null;
    }
    final previous = _loadedEpisode;
    if (previous != null && previous.id != episode.id) {
      unawaited(_saveLoadedPosition(force: true));
    }
    _loadedEpisode = episode;
    _loadedUrl = url;
    _loadedAfterRefresh = renewed;
    _loadedPosition = from;
    _loadedDuration = _durationOf(episode);
    _lastSavedPosition = from;
    _sawPlaying = false;
    playerStatus = PlayerStatus.loading;
    activeCitationId = citationId;
    _clearErrors((error) => error.kind == ErrorKind.playback);
    if (episode.id == selectedEpisode?.episode.id) {
      _positionDismissed = false;
      _setSelectedProgress(PlaybackProgress(
          position: from,
          duration: _loadedDuration ?? selectedProgress.value.duration));
    }
    _notify();
    try {
      await _audioOutput.playEpisode(url,
          seekTo: from, media: _mediaFor(episode));
      if (_closed || generation != _playbackGeneration) return;
      playerStatus = PlayerStatus.playing;
    } catch (error) {
      if (!_closed && generation == _playbackGeneration) {
        if (!renewed) {
          final fresh = await _renewPlaybackLink(episode, failedUrl: url);
          if (_closed || generation != _playbackGeneration) return;
          if (fresh != null) {
            await _startPlayback(fresh,
                from: from, citationId: citationId, renewed: true);
            return;
          }
        }
        playerStatus = PlayerStatus.paused;
        activeCitationId = null;
        _fail(ErrorKind.playback, error, _playbackFailedMessage);
      }
    } finally {
      if (generation == _playbackGeneration) _notify();
    }
  }

  /// Fetches the episode again for a fresh playback link. Returns the
  /// episode when its link changed, else null.
  Future<EpisodeDetail?> _renewPlaybackLink(EpisodeDetail episode,
      {required String failedUrl}) async {
    try {
      final envelope = await _api.getEpisode(episode.id);
      if (_closed) return null;
      _applyDetail(envelope);
      final fresh = _episodeCache[episode.id] ?? envelope.episode;
      return fresh.playbackUrl.isNotEmpty && fresh.playbackUrl != failedUrl
          ? fresh
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Stops the episode and any spoken answer, remembering the position.
  Future<void> stopAudio() async {
    ++_playbackGeneration;
    if (voiceState == VoiceState.speaking) {
      ++_questionGeneration;
      voiceState = VoiceState.idle;
      isPreparingSpeech = false;
    }
    final saving = _saveLoadedPosition(force: true);
    _loadedEpisode = null;
    _loadedUrl = null;
    playerStatus = PlayerStatus.stopped;
    activeCitationId = null;
    _resumeAfterQuestion = false;
    _capturedPosition = null;
    await Future.wait([_audioOutput.stop(), saving]);
    _notify();
  }

  void _updateLoadedPosition(Duration position) {
    _loadedPosition = position;
    final episode = _loadedEpisode;
    if (episode != null && episode.id == selectedEpisode?.episode.id) {
      _setSelectedProgress(PlaybackProgress(
          position: position,
          duration: _loadedDuration ?? selectedProgress.value.duration));
    }
  }

  void _onProgress(EpisodeProgress progress) {
    final episode = _loadedEpisode;
    if (_closed ||
        episode == null ||
        progress.url != _loadedUrl ||
        playerStatus == PlayerStatus.loading ||
        playerStatus == PlayerStatus.stopped) {
      return;
    }
    if (progress.completed) {
      _onCompleted(episode);
      return;
    }
    final duration = progress.duration;
    if (duration != null && duration > Duration.zero) {
      _loadedDuration = duration;
    }
    _updateLoadedPosition(progress.position);
    // Follow pauses and resumes that did not come from the app, such as an
    // audio interruption. Ignore stale updates from before playback began.
    if (progress.playing) {
      _sawPlaying = true;
      if (playerStatus == PlayerStatus.paused) {
        playerStatus = PlayerStatus.playing;
        _notify();
      }
    } else if (playerStatus == PlayerStatus.playing && _sawPlaying) {
      playerStatus = PlayerStatus.paused;
      activeCitationId = null;
      unawaited(_saveLoadedPosition(force: true));
      _notify();
      return;
    }
    if (playerStatus == PlayerStatus.playing) unawaited(_saveLoadedPosition());
  }

  void _onCompleted(EpisodeDetail episode) {
    ++_playbackGeneration;
    playerStatus = PlayerStatus.stopped;
    activeCitationId = null;
    _loadedPosition = Duration.zero;
    _lastSavedPosition = Duration.zero;
    unawaited(_clearPosition(episode.id));
    if (episode.id == selectedEpisode?.episode.id) {
      _setSelectedProgress(PlaybackProgress(
          duration: _loadedDuration ?? selectedProgress.value.duration));
    }
    _notify();
  }

  void _onPlaybackError(Object error) {
    if (_closed || playerStatus != PlayerStatus.playing) return;
    final generation = ++_playbackGeneration;
    playerStatus = PlayerStatus.paused;
    activeCitationId = null;
    _fail(ErrorKind.playback, error, _playbackFailedMessage);
    unawaited(_saveLoadedPosition(force: true));
    _notify();
    final episode = _loadedEpisode;
    final url = _loadedUrl;
    if (episode != null && url != null && !_loadedAfterRefresh) {
      unawaited(_resumeWithRenewedLink(episode, url, generation));
    }
  }

  /// After the stream broke (e.g. its signed link expired), continues from
  /// the same position with a renewed link, if there is one.
  Future<void> _resumeWithRenewedLink(
      EpisodeDetail episode, String failedUrl, int generation) async {
    final fresh = await _renewPlaybackLink(episode, failedUrl: failedUrl);
    if (fresh == null ||
        _closed ||
        generation != _playbackGeneration ||
        !canControlPlayback) {
      return;
    }
    await _startPlayback(fresh, from: _loadedPosition, renewed: true);
  }

  void _onRemoteCommand(RemoteCommand command) {
    if (_closed || !canControlPlayback) return;
    switch (command) {
      case RemotePlay():
        unawaited(_resumeFromRemote());
      case RemotePause():
        unawaited(pausePlayback());
      case RemoteStop():
        unawaited(stopAudio());
      case RemoteSeek(:final position):
        unawaited(seekNowPlaying(position));
      case RemoteSkip(:final offset):
        final current = nowPlaying != null
            ? _loadedPosition
            : selectedProgress.value.position;
        unawaited(seekNowPlaying(current + offset));
    }
  }

  Future<void> _resumeFromRemote() async {
    if (isAudioPlaying) return;
    final episode = nowPlaying;
    if (episode != null) {
      await _startPlayback(episode, from: _loadedPosition);
    } else {
      await playSelectedEpisode();
    }
  }

  /// Saves the position of the episode in the player, e.g. when the app
  /// moves to the background.
  Future<void> savePlaybackPosition() => _saveLoadedPosition(force: true);

  Future<void> _saveLoadedPosition({bool force = false}) async {
    final episode = _loadedEpisode;
    if (episode == null || playerStatus == PlayerStatus.loading) return;
    final position = _loadedPosition;
    if (!force && (position - _lastSavedPosition).abs() < _saveEvery) return;
    _lastSavedPosition = position;
    await _storePosition(
        episode.id, position, _loadedDuration ?? _durationOf(episode));
  }

  Future<void> _storePosition(
      String episodeId, Duration position, Duration? duration) async {
    final finished = duration != null &&
        duration > PodcastController.finishedMargin &&
        position >= duration - PodcastController.finishedMargin;
    if (position < const Duration(seconds: 1) || finished) {
      await _clearPosition(episodeId);
      return;
    }
    try {
      await _positions.save(episodeId, position);
    } catch (_) {
      // Losing a resume position is not worth interrupting playback.
    }
  }

  Future<void> _clearPosition(String episodeId) async {
    try {
      await _positions.clear(episodeId);
    } catch (_) {
      // See _storePosition.
    }
  }

  Future<Duration?> _loadSavedPosition(String episodeId) async {
    try {
      return await _positions.load(episodeId);
    } catch (_) {
      // A lost resume position only means starting from the beginning.
      return null;
    }
  }
}
