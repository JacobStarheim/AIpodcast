import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'media_session.dart';

export 'media_session.dart'
    show
        EpisodeMedia,
        RemoteCommand,
        RemotePause,
        RemotePlay,
        RemoteSeek,
        RemoteSkip,
        RemoteStop;

/// State of the episode player for the episode at [url].
class EpisodeProgress {
  const EpisodeProgress({
    required this.url,
    required this.position,
    required this.playing,
    this.duration,
    this.completed = false,
  });

  final String url;
  final Duration position;
  final Duration? duration;
  final bool playing;

  /// Playback reached the end of the episode.
  final bool completed;
}

abstract class AudioOutput {
  /// Progress of the loaded episode. Playback failures arrive as errors.
  Stream<EpisodeProgress> get episodeProgress;

  /// Play, pause and seek requests from the lock screen, notification and
  /// headset. The app decides whether and how to follow them.
  Stream<RemoteCommand> get remoteCommands;

  /// Loads [url] unless it is already loaded, moves to [seekTo] when given
  /// and starts playback, showing [media] on the lock screen. Completes once
  /// playback has started; follow [episodeProgress] for what happens next.
  Future<void> playEpisode(String url, {Duration? seekTo, EpisodeMedia? media});

  /// Pauses the episode and returns the position it paused at.
  Future<Duration> pauseEpisode();

  /// Moves the loaded episode to [position] without starting or pausing it.
  Future<void> seekEpisode(Duration position);

  /// Plays a spoken answer after pausing the episode. Completes when the
  /// speech ends or is stopped.
  Future<void> playTtsBytes(Uint8List audioBytes,
      {String mimeType = 'audio/mpeg'});

  /// Stops a spoken answer and leaves the episode paused.
  Future<void> stopSpeech();

  /// Stops the episode and any spoken answer.
  Future<void> stop();
  Future<void> dispose();
}

/// Plays episodes and spoken answers with two just_audio players.
///
/// Only the episode player is mirrored to [mediaSession] (lock screen,
/// notification, background playback); spoken answers pause the episode and
/// play on their own player, so asking while listening keeps working.
class JustAudioOutput implements AudioOutput {
  JustAudioOutput({
    AudioPlayer? episodePlayer,
    AudioPlayer? ttsPlayer,
    PodcastMediaHandler? mediaSession,
  })  : _episodePlayer = episodePlayer ?? AudioPlayer(),
        _ttsPlayer = ttsPlayer ?? AudioPlayer(),
        _media = mediaSession;

  final AudioPlayer _episodePlayer;
  final AudioPlayer _ttsPlayer;
  final PodcastMediaHandler? _media;

  /// What the lock screen shows; null while nothing is loaded.
  EpisodeMedia? _shownMedia;
  late final StreamController<EpisodeProgress> _progress =
      StreamController<EpisodeProgress>.broadcast(
          onListen: _listenToPlayer, onCancel: _stopListening);
  final List<StreamSubscription<Object?>> _subscriptions = [];
  String? _currentEpisodeUrl;
  File? _ttsFile;
  int _generation = 0;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _completed = false;

  @override
  Stream<EpisodeProgress> get episodeProgress => _progress.stream;

  @override
  Stream<RemoteCommand> get remoteCommands =>
      _media?.commands ?? const Stream<RemoteCommand>.empty();

  void _listenToPlayer() {
    _subscriptions.addAll([
      _episodePlayer.positionStream.listen((position) {
        _position = position;
        _emit();
      }),
      _episodePlayer.durationStream.listen((duration) {
        _duration = duration;
        if (duration != null && _shownMedia != null) {
          _media?.showDuration(duration);
        }
        _emit();
      }),
      _episodePlayer.playerStateStream.listen((state) {
        final completed = state.processingState == ProcessingState.completed;
        _playing = state.playing && !completed;
        final justCompleted = completed && !_completed;
        _completed = completed;
        _emit();
        _showPlaybackState(state.processingState);
        // just_audio keeps `playing` true after completion; pause so that a
        // later play request starts playback again.
        if (justCompleted) unawaited(_episodePlayer.pause());
      }),
      _episodePlayer.playbackEventStream.listen(
          (event) => _showPlaybackState(event.processingState),
          onError: (Object error, StackTrace stackTrace) {
        if (error is PlayerInterruptedException) return;
        if (!_progress.isClosed) _progress.addError(error, stackTrace);
      }),
    ]);
  }

  /// Mirrors the episode player to the lock screen and notification.
  void _showPlaybackState(ProcessingState state) {
    final media = _media;
    if (media == null || _shownMedia == null) return;
    media.showPlayback(
      playing: _playing,
      processingState: mediaProcessingState(state),
      position: _episodePlayer.position,
      bufferedPosition: _episodePlayer.bufferedPosition,
      speed: _episodePlayer.speed,
    );
  }

  Future<void> _stopListening() async {
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  void _emit() {
    final url = _currentEpisodeUrl;
    if (url == null || _progress.isClosed) return;
    _progress.add(EpisodeProgress(
      url: url,
      position: _position,
      duration: _duration,
      playing: _playing,
      completed: _completed,
    ));
  }

  @override
  Future<void> playEpisode(String url,
      {Duration? seekTo, EpisodeMedia? media}) async {
    final generation = ++_generation;
    if (media != null) {
      _shownMedia = media;
      // The player's own length beats the feed's estimate once it is known.
      _media?.showEpisode(media,
          duration: url == _currentEpisodeUrl ? _duration : null);
    }
    await _ttsPlayer.stop();
    if (generation != _generation) return;
    if (_currentEpisodeUrl != url) {
      _currentEpisodeUrl = null;
      _position = seekTo ?? Duration.zero;
      _duration = null;
      _completed = false;
      await _episodePlayer.setUrl(url, initialPosition: seekTo);
      if (generation != _generation) return;
      _currentEpisodeUrl = url;
    } else if (seekTo != null) {
      await _episodePlayer.seek(seekTo);
      if (generation != _generation) return;
    }
    // play() completes only when playback pauses or ends, so do not wait.
    unawaited(_episodePlayer.play().catchError((Object error, StackTrace stack) {
      if (!_progress.isClosed) _progress.addError(error, stack);
    }));
  }

  @override
  Future<Duration> pauseEpisode() async {
    // Also cancels a playEpisode that is still loading.
    ++_generation;
    await _episodePlayer.pause();
    return _episodePlayer.position;
  }

  @override
  Future<void> seekEpisode(Duration position) async {
    if (_currentEpisodeUrl == null) return;
    _position = position;
    await _episodePlayer.seek(position);
  }

  @override
  Future<void> playTtsBytes(Uint8List audioBytes,
      {String mimeType = 'audio/mpeg'}) async {
    // Capture ownership before awaiting native calls. A newer user stop
    // must cancel this request even while those calls are still pending.
    final generation = ++_generation;
    await Future.wait([_episodePlayer.pause(), _ttsPlayer.stop()]);
    if (generation != _generation) return;
    await _deleteTtsFile();
    final directory = await getTemporaryDirectory();
    if (generation != _generation) return;
    final extension = switch (mimeType.split(';').first.trim()) {
      'audio/wav' || 'audio/x-wav' => 'wav',
      'audio/mp4' || 'audio/aac' => 'm4a',
      'audio/ogg' => 'ogg',
      _ => 'mp3',
    };
    final file = File(
      '${directory.path}/podcast-answer-${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    _ttsFile = file;
    await file.writeAsBytes(audioBytes, flush: true);
    if (generation != _generation) return;
    // Use the matching file type for native AVPlayer/ExoPlayer decoding.
    await _ttsPlayer.setFilePath(file.path);
    if (generation != _generation) return;
    await _ttsPlayer.play();
  }

  @override
  Future<void> stopSpeech() async {
    ++_generation;
    await _ttsPlayer.stop();
  }

  @override
  Future<void> stop() async {
    ++_generation;
    _hideMedia();
    await Future.wait([_episodePlayer.stop(), _ttsPlayer.stop()]);
  }

  void _hideMedia() {
    if (_shownMedia == null) return;
    _shownMedia = null;
    _media?.showStopped();
  }

  Future<void> _deleteTtsFile() async {
    final file = _ttsFile;
    _ttsFile = null;
    if (file != null && await file.exists()) await file.delete();
  }

  @override
  Future<void> dispose() async {
    ++_generation;
    _hideMedia();
    await _stopListening();
    await _progress.close();
    await _episodePlayer.dispose();
    await _ttsPlayer.dispose();
    await _deleteTtsFile();
  }
}

AudioProcessingState mediaProcessingState(ProcessingState state) =>
    switch (state) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
