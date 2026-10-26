import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:podcast_voice_ai/audio_output.dart';

class _DelayedPlayer extends Fake implements AudioPlayer {
  final firstCall = Completer<void>();
  int stopCalls = 0;
  int pauseCalls = 0;
  int playCalls = 0;

  @override
  Future<void> stop() async {
    stopCalls += 1;
    if (stopCalls + pauseCalls == 1) await firstCall.future;
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    if (stopCalls + pauseCalls == 1) await firstCall.future;
  }

  @override
  Future<void> play() async {
    playCalls += 1;
  }

  @override
  Duration get position => const Duration(seconds: 42);
}

void main() {
  test('a newer stop cancels speech awaiting initial native player calls',
      () async {
    final episodePlayer = _DelayedPlayer();
    final ttsPlayer = _DelayedPlayer();
    final audio = JustAudioOutput(
      episodePlayer: episodePlayer,
      ttsPlayer: ttsPlayer,
    );

    final speech = audio.playTtsBytes(Uint8List.fromList([1, 2, 3]),
        mimeType: 'audio/wav');
    expect(episodePlayer.pauseCalls, 1,
        reason: 'speech pauses the episode instead of stopping it');
    expect(episodePlayer.stopCalls, 0);
    expect(ttsPlayer.stopCalls, 1);
    await audio.stop();
    episodePlayer.firstCall.complete();
    ttsPlayer.firstCall.complete();
    await speech;

    expect(episodePlayer.playCalls, 0);
    expect(ttsPlayer.playCalls, 0);
  });

  test('pausing reports where the episode paused', () async {
    final episodePlayer = _DelayedPlayer()..firstCall.complete();
    final audio = JustAudioOutput(
        episodePlayer: episodePlayer, ttsPlayer: _DelayedPlayer());
    expect(await audio.pauseEpisode(), const Duration(seconds: 42));
    expect(episodePlayer.pauseCalls, 1);
  });

  test('stopping speech leaves the episode player alone', () async {
    final episodePlayer = _DelayedPlayer();
    final ttsPlayer = _DelayedPlayer()..firstCall.complete();
    final audio =
        JustAudioOutput(episodePlayer: episodePlayer, ttsPlayer: ttsPlayer);
    await audio.stopSpeech();
    expect(ttsPlayer.stopCalls, 1);
    expect(episodePlayer.stopCalls + episodePlayer.pauseCalls, 0);
  });
}
