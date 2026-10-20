import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

abstract class AudioOutput {
  Future<void> playEpisode(String url, {Duration? seekTo});
  Future<void> seekEpisode(Duration position);
  Future<void> playTtsBytes(Uint8List audioBytes,
      {String mimeType = 'audio/mpeg'});
  Future<void> stop();
  Future<void> dispose();
}

class JustAudioOutput implements AudioOutput {
  JustAudioOutput({AudioPlayer? episodePlayer, AudioPlayer? ttsPlayer})
      : _episodePlayer = episodePlayer ?? AudioPlayer(),
        _ttsPlayer = ttsPlayer ?? AudioPlayer();

  final AudioPlayer _episodePlayer;
  final AudioPlayer _ttsPlayer;
  String? _currentEpisodeUrl;
  File? _ttsFile;
  int _generation = 0;

  @override
  Future<void> playEpisode(String url, {Duration? seekTo}) async {
    final generation = ++_generation;
    await _ttsPlayer.stop();
    if (generation != _generation) return;
    if (_currentEpisodeUrl != url) {
      await _episodePlayer.setUrl(url);
      if (generation != _generation) return;
      _currentEpisodeUrl = url;
    }
    if (seekTo != null) await _episodePlayer.seek(seekTo);
    if (generation != _generation) return;
    await _episodePlayer.play();
  }

  @override
  Future<void> seekEpisode(Duration position) async {
    if (_currentEpisodeUrl == null) return;
    final generation = ++_generation;
    await _ttsPlayer.stop();
    if (generation != _generation) return;
    await _episodePlayer.seek(position);
    if (generation != _generation) return;
    await _episodePlayer.play();
  }

  @override
  Future<void> playTtsBytes(Uint8List audioBytes,
      {String mimeType = 'audio/mpeg'}) async {
    // Capture ownership before awaiting native stop calls. A newer user stop
    // must cancel this request even while those calls are still pending.
    final generation = ++_generation;
    await Future.wait([_episodePlayer.stop(), _ttsPlayer.stop()]);
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
  Future<void> stop() async {
    ++_generation;
    await Future.wait([_episodePlayer.stop(), _ttsPlayer.stop()]);
  }

  Future<void> _deleteTtsFile() async {
    final file = _ttsFile;
    _ttsFile = null;
    if (file != null && await file.exists()) await file.delete();
  }

  @override
  Future<void> dispose() async {
    ++_generation;
    await _episodePlayer.dispose();
    await _ttsPlayer.dispose();
    await _deleteTtsFile();
  }
}
