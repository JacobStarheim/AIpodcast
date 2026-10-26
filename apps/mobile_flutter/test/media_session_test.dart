import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:podcast_voice_ai/audio_output.dart';
import 'package:podcast_voice_ai/media_session.dart';

/// An episode player whose state the test drives.
class _StreamingPlayer extends Fake implements AudioPlayer {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration?>.broadcast(sync: true);
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final events = StreamController<PlaybackEvent>.broadcast(sync: true);
  final List<String> calls = [];
  Duration current = Duration.zero;

  void report(bool playing, ProcessingState state) =>
      states.add(PlayerState(playing, state));

  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => events.stream;
  @override
  Duration get position => current;
  @override
  Duration get bufferedPosition => current;
  @override
  double get speed => 1;

  @override
  Future<Duration?> setUrl(String url,
      {Map<String, String>? headers,
      Duration? initialPosition,
      bool preload = true,
      dynamic tag}) async {
    calls.add('setUrl $url@${initialPosition?.inSeconds}');
    current = initialPosition ?? Duration.zero;
    return null;
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration? position, {int? index}) async =>
      calls.add('seek ${position?.inSeconds}');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> dispose() async => calls.add('dispose');
}

const _media = EpisodeMedia(
  id: 'ep1',
  title: 'The budget debate',
  podcast: 'Public Money',
  artworkUrl: 'https://img.example/pm.jpg',
  duration: Duration(minutes: 30),
);

void main() {
  group('PodcastMediaHandler', () {
    test('turns system controls into commands for the app', () async {
      final handler = PodcastMediaHandler();
      final commands = <RemoteCommand>[];
      handler.commands.listen(commands.add);

      await handler.play();
      await handler.pause();
      await handler.seek(const Duration(minutes: 3));
      await handler.seek(const Duration(seconds: -4));
      await handler.rewind();
      await handler.fastForward();
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.stop();
      await Future<void>.delayed(Duration.zero);

      expect(commands[0], isA<RemotePlay>());
      expect(commands[1], isA<RemotePause>());
      expect((commands[2] as RemoteSeek).position, const Duration(minutes: 3));
      expect((commands[3] as RemoteSeek).position, Duration.zero);
      expect((commands[4] as RemoteSkip).offset, const Duration(seconds: -15));
      expect((commands[5] as RemoteSkip).offset, const Duration(seconds: 30));
      expect((commands[6] as RemoteSkip).offset, const Duration(seconds: 30));
      expect((commands[7] as RemoteSkip).offset, const Duration(seconds: -15));
      expect(commands[8], isA<RemoteStop>());
    });

    test('a headset click pauses while playing and plays while paused',
        () async {
      final handler = PodcastMediaHandler();
      final commands = <RemoteCommand>[];
      handler.commands.listen(commands.add);
      handler.showPlayback(
          playing: true,
          processingState: AudioProcessingState.ready,
          position: Duration.zero);
      await handler.click();
      handler.showPlayback(
          playing: false,
          processingState: AudioProcessingState.ready,
          position: Duration.zero);
      await handler.click();
      await Future<void>.delayed(Duration.zero);
      expect(commands.map((command) => command.runtimeType),
          [RemotePause, RemotePlay]);
    });

    test('shows the episode with title, podcast, artwork and length', () {
      final handler = PodcastMediaHandler()..showEpisode(_media);
      final item = handler.mediaItem.value!;
      expect(item.id, 'ep1');
      expect(item.title, 'The budget debate');
      expect(item.artist, 'Public Money');
      expect(item.album, 'Public Money');
      expect(item.artUri, Uri.parse('https://img.example/pm.jpg'));
      expect(item.duration, const Duration(minutes: 30));

      handler.showDuration(const Duration(minutes: 31));
      expect(handler.mediaItem.value!.duration, const Duration(minutes: 31));

      handler.showEpisode(const EpisodeMedia(
          id: 'ep2', title: 'T', podcast: 'P', artworkUrl: 'file:///x.png'));
      expect(handler.mediaItem.value!.artUri, isNull,
          reason: 'only web artwork is shown');
    });

    test('offers back 15 s, play or pause and forward 30 s', () {
      final handler = PodcastMediaHandler()
        ..showPlayback(
            playing: true,
            processingState: AudioProcessingState.ready,
            position: const Duration(seconds: 42));
      var state = handler.playbackState.value;
      expect(state.controls,
          [MediaControl.rewind, MediaControl.pause, MediaControl.fastForward]);
      expect(state.androidCompactActionIndices, [0, 1, 2]);
      expect(state.systemActions, contains(MediaAction.seek));
      expect(state.playing, isTrue);
      expect(state.updatePosition, const Duration(seconds: 42));

      handler.showPlayback(
          playing: false,
          processingState: AudioProcessingState.ready,
          position: const Duration(seconds: 42));
      state = handler.playbackState.value;
      expect(state.controls[1], MediaControl.play);

      handler.showStopped();
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.idle);
      expect(handler.mediaItem.value, isNull);
    });

    test('the service configuration matches the skip buttons', () {
      expect(mediaServiceConfig.rewindInterval, const Duration(seconds: 15));
      expect(
          mediaServiceConfig.fastForwardInterval, const Duration(seconds: 30));
      expect(mediaServiceConfig.androidNotificationIcon,
          'drawable/ic_stat_podcast');
      expect(
          File('android/app/src/main/res/drawable/ic_stat_podcast.xml')
              .existsSync(),
          isTrue);
      expect(mediaServiceConfig.androidStopForegroundOnPause, isTrue);
    });
  });

  group('JustAudioOutput with a media session', () {
    test('mirrors the episode player to the lock screen', () async {
      final player = _StreamingPlayer();
      final handler = PodcastMediaHandler();
      final audio = JustAudioOutput(
          episodePlayer: player,
          ttsPlayer: _StreamingPlayer(),
          mediaSession: handler);
      final subscription = audio.episodeProgress.listen((_) {});

      await audio.playEpisode('https://media.example/ep1.mp3',
          seekTo: const Duration(seconds: 90), media: _media);
      expect(handler.mediaItem.value!.title, 'The budget debate');
      expect(player.calls, contains('setUrl https://media.example/ep1.mp3@90'));

      player.current = const Duration(seconds: 91);
      player.report(true, ProcessingState.ready);
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.ready);
      expect(handler.playbackState.value.updatePosition,
          const Duration(seconds: 91));

      player.durations.add(const Duration(minutes: 32));
      expect(handler.mediaItem.value!.duration, const Duration(minutes: 32));

      player.report(false, ProcessingState.ready);
      expect(handler.playbackState.value.playing, isFalse);

      await audio.stop();
      expect(handler.mediaItem.value, isNull);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.idle);
      await subscription.cancel();
    });

    test('lock screen commands reach the app, not the player', () async {
      final player = _StreamingPlayer();
      final handler = PodcastMediaHandler();
      final audio = JustAudioOutput(
          episodePlayer: player,
          ttsPlayer: _StreamingPlayer(),
          mediaSession: handler);
      final commands = <RemoteCommand>[];
      audio.remoteCommands.listen(commands.add);
      await handler.pause();
      await handler.fastForward();
      await Future<void>.delayed(Duration.zero);
      expect(commands.map((command) => command.runtimeType),
          [RemotePause, RemoteSkip]);
      expect(player.calls, isEmpty,
          reason: 'the controller decides, e.g. during a question');
    });

    test('a spoken answer pauses the episode on its own player', () async {
      final player = _StreamingPlayer();
      final handler = PodcastMediaHandler();
      final audio = JustAudioOutput(
          episodePlayer: player,
          ttsPlayer: _StreamingPlayer(),
          mediaSession: handler);
      final subscription = audio.episodeProgress.listen((_) {});
      await audio.playEpisode('https://media.example/ep1.mp3', media: _media);
      player.report(true, ProcessingState.ready);
      // Writing the speech file needs path_provider, which tests lack; the
      // episode is paused before that.
      await expectLater(
          audio.playTtsBytes(Uint8List.fromList([1, 2, 3]),
              mimeType: 'audio/wav'),
          throwsA(anything));
      expect(player.calls, contains('pause'));
      expect(player.calls.where((call) => call == 'stop'), isEmpty);
      player.report(false, ProcessingState.ready);
      expect(handler.mediaItem.value!.id, 'ep1',
          reason: 'the paused episode stays on the lock screen');
      await subscription.cancel();
    });

    test('disposing removes the episode from the lock screen', () async {
      final handler = PodcastMediaHandler();
      final audio = JustAudioOutput(
          episodePlayer: _StreamingPlayer(),
          ttsPlayer: _StreamingPlayer(),
          mediaSession: handler);
      await audio.playEpisode('https://media.example/ep1.mp3', media: _media);
      await audio.dispose();
      expect(handler.mediaItem.value, isNull);
    });

    test('without a media session there are no remote commands', () async {
      final audio = JustAudioOutput(
          episodePlayer: _StreamingPlayer(), ttsPlayer: _StreamingPlayer());
      expect(await audio.remoteCommands.isEmpty, isTrue);
    });
  });

  group('platform configuration', () {
    test('iOS may play audio in the background', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(
          RegExp(r'<key>UIBackgroundModes</key>\s*<array>\s*<string>audio</string>')
              .hasMatch(plist),
          isTrue);
    });

    test('Android declares the playback service and its permissions', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      for (final permission in [
        'android.permission.WAKE_LOCK',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
      ]) {
        expect(manifest, contains('android:name="$permission"'));
      }
      expect(manifest, contains('com.ryanheise.audioservice.AudioService'));
      expect(
          manifest, contains('android:foregroundServiceType="mediaPlayback"'));
      expect(
          manifest, contains('com.ryanheise.audioservice.MediaButtonReceiver'));
      final activity = File(
              'android/app/src/main/kotlin/io/github/jacobstarheim/aipodcast/MainActivity.kt')
          .readAsStringSync();
      expect(activity, contains('AudioServiceActivity()'));
    });
  });
}
