import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

abstract class AudioOutput {
  Future<void> playEpisode(String url, {Duration? seekTo});
  Future<void> seekEpisode(Duration position);
  Future<void> playTtsBytes(Uint8List mp3Bytes);
  Future<void> dispose();
}

class JustAudioOutput implements AudioOutput {
  final AudioPlayer _episodePlayer = AudioPlayer();
  final AudioPlayer _ttsPlayer = AudioPlayer();

  String? _currentEpisodeUrl;

  @override
  Future<void> playEpisode(String url, {Duration? seekTo}) async {
    if (_currentEpisodeUrl != url) {
      await _episodePlayer.setUrl(url);
      _currentEpisodeUrl = url;
    }

    if (seekTo != null) {
      await _episodePlayer.seek(seekTo);
    }

    await _episodePlayer.play();
  }

  @override
  Future<void> seekEpisode(Duration position) async {
    if (_currentEpisodeUrl == null) {
      return;
    }

    await _episodePlayer.seek(position);
    await _episodePlayer.play();
  }

  @override
  Future<void> playTtsBytes(Uint8List mp3Bytes) async {
    final dataUri = Uri.dataFromBytes(mp3Bytes, mimeType: 'audio/mpeg').toString();
    await _ttsPlayer.setUrl(dataUri);
    await _ttsPlayer.play();
  }

  @override
  Future<void> dispose() async {
    await _episodePlayer.dispose();
    await _ttsPlayer.dispose();
  }
}
