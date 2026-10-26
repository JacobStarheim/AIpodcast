import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

/// What the lock screen, notification and car show about the episode.
class EpisodeMedia {
  const EpisodeMedia({
    required this.id,
    required this.title,
    required this.podcast,
    this.artworkUrl,
    this.duration,
  });

  final String id;
  final String title;
  final String podcast;
  final String? artworkUrl;
  final Duration? duration;
}

/// A playback command from outside the app: lock screen, notification,
/// headset buttons, a watch or a car.
sealed class RemoteCommand {
  const RemoteCommand();
}

class RemotePlay extends RemoteCommand {
  const RemotePlay();
}

class RemotePause extends RemoteCommand {
  const RemotePause();
}

class RemoteStop extends RemoteCommand {
  const RemoteStop();
}

/// Move to [position], e.g. from the lock screen scrubber.
class RemoteSeek extends RemoteCommand {
  const RemoteSeek(this.position);
  final Duration position;
}

/// Move by [offset] from the current position (negative to go back).
class RemoteSkip extends RemoteCommand {
  const RemoteSkip(this.offset);
  final Duration offset;
}

const rewindInterval = Duration(seconds: 15);
const fastForwardInterval = Duration(seconds: 30);

/// Lock screen and notification settings. The skip intervals also label the
/// iOS skip buttons.
const mediaServiceConfig = AudioServiceConfig(
  androidNotificationChannelId: 'io.github.jacobstarheim.aipodcast.playback',
  androidNotificationChannelName: 'Playback',
  androidNotificationChannelDescription:
      'Controls for the episode that is playing',
  androidNotificationIcon: 'drawable/ic_stat_podcast',
  notificationColor: Color(0xFF365B43),
  androidStopForegroundOnPause: true,
  artDownscaleWidth: 512,
  artDownscaleHeight: 512,
  rewindInterval: rewindInterval,
  fastForwardInterval: fastForwardInterval,
);

/// The system media session for the episode player.
///
/// It only mirrors the episode player (spoken answers use their own player
/// and are not shown) and turns system controls into [commands]. The app
/// decides what a command does, so questions in progress and the
/// pause-answer-resume flow keep their rules.
class PodcastMediaHandler extends BaseAudioHandler {
  PodcastMediaHandler();

  final StreamController<RemoteCommand> _commands =
      StreamController<RemoteCommand>.broadcast();

  Stream<RemoteCommand> get commands => _commands.stream;

  Future<void> _send(RemoteCommand command) async {
    if (!_commands.isClosed) _commands.add(command);
  }

  @override
  Future<void> play() => _send(const RemotePlay());

  @override
  Future<void> pause() => _send(const RemotePause());

  @override
  Future<void> stop() => _send(const RemoteStop());

  @override
  Future<void> seek(Duration position) =>
      _send(RemoteSeek(position.isNegative ? Duration.zero : position));

  @override
  Future<void> rewind() => _send(RemoteSkip(-rewindInterval));

  @override
  Future<void> fastForward() => _send(const RemoteSkip(fastForwardInterval));

  /// Headset and car "next"/"previous" buttons skip within the episode.
  @override
  Future<void> skipToNext() => fastForward();

  @override
  Future<void> skipToPrevious() => rewind();

  @override
  Future<void> onNotificationDeleted() => stop();

  /// Shows [media] as the item that is playing; [duration] overrides its
  /// length.
  void showEpisode(EpisodeMedia media, {Duration? duration}) {
    final art =
        media.artworkUrl == null ? null : Uri.tryParse(media.artworkUrl!);
    mediaItem.add(MediaItem(
      id: media.id,
      title: media.title,
      artist: media.podcast,
      album: media.podcast,
      duration: duration ?? media.duration,
      artUri: art != null && (art.scheme == 'https' || art.scheme == 'http')
          ? art
          : null,
    ));
  }

  /// Updates the length once the player knows it.
  void showDuration(Duration duration) {
    final item = mediaItem.value;
    if (item == null ||
        duration <= Duration.zero ||
        item.duration == duration) {
      return;
    }
    mediaItem.add(item.copyWith(duration: duration));
  }

  void showPlayback({
    required bool playing,
    required AudioProcessingState processingState,
    required Duration position,
    Duration bufferedPosition = Duration.zero,
    double speed = 1,
  }) {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processingState,
      playing: playing,
      updatePosition: position,
      bufferedPosition: bufferedPosition,
      speed: speed,
    ));
  }

  /// Removes the episode from the lock screen and notification.
  void showStopped() {
    playbackState.add(PlaybackState());
    mediaItem.add(null);
  }
}

/// Spoken word: iOS spoken-audio mode (other speech pauses instead of
/// ducking under it) and Android speech attributes.
const AudioSessionConfiguration podcastAudioSession =
    AudioSessionConfiguration.speech();

/// Configures the shared audio session for podcast playback. The recorder
/// switches it to recording, so this runs again after each recording.
Future<void> configureAudioSession() async {
  try {
    final session = await AudioSession.instance;
    await session.configure(podcastAudioSession);
  } catch (error) {
    debugPrint('Audio session configuration failed: $error');
  }
}

/// Registers [PodcastMediaHandler] as the app's media session, for
/// background playback and lock screen controls. Without platform support
/// (e.g. in tests or on desktop) the handler still works, unregistered.
Future<PodcastMediaHandler> startMediaSession() async {
  await configureAudioSession();
  try {
    return await AudioService.init(
      builder: PodcastMediaHandler.new,
      config: mediaServiceConfig,
    );
  } catch (error) {
    debugPrint('Background playback is unavailable: $error');
    return PodcastMediaHandler();
  }
}
