import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:podcast_voice_ai/audio_output.dart';

class _DelayedStopPlayer extends Fake implements AudioPlayer {
  final firstStop = Completer<void>();
  int stopCalls = 0;
  int playCalls = 0;

  @override
  Future<void> stop() async {
    stopCalls += 1;
    if (stopCalls == 1) await firstStop.future;
  }

  @override
  Future<void> play() async {
    playCalls += 1;
  }
}

void main() {
  test('a newer stop cancels speech awaiting initial native player stops',
      () async {
    final episodePlayer = _DelayedStopPlayer();
    final ttsPlayer = _DelayedStopPlayer();
    final audio = JustAudioOutput(
      episodePlayer: episodePlayer,
      ttsPlayer: ttsPlayer,
    );

    final speech = audio.playTtsBytes(Uint8List.fromList([1, 2, 3]),
        mimeType: 'audio/wav');
    expect(episodePlayer.stopCalls, 1);
    expect(ttsPlayer.stopCalls, 1);
    await audio.stop();
    episodePlayer.firstStop.complete();
    ttsPlayer.firstStop.complete();
    await speech;

    expect(episodePlayer.playCalls, 0);
    expect(ttsPlayer.playCalls, 0);
  });
}
