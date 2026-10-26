import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

abstract class VoiceRecorder {
  Future<void> start();
  Future<String?> stop();
  Future<void> dispose();
}

class RecordVoiceRecorder implements VoiceRecorder {
  /// [onStopped] runs after each recording, e.g. to hand the audio session
  /// back to playback (recording switches it to play-and-record on iOS).
  RecordVoiceRecorder({this.onStopped});

  final Future<void> Function()? onStopped;
  final AudioRecorder _recorder = AudioRecorder();

  @override
  Future<void> start() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw Exception('Microphone permission denied');
    }

    final tempDirectory = await getTemporaryDirectory();
    final outputPath =
        '${tempDirectory.path}/question_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: outputPath,
    );
  }

  @override
  Future<String?> stop() async {
    try {
      return await _recorder.stop();
    } finally {
      await onStopped?.call();
    }
  }

  @override
  Future<void> dispose() {
    return _recorder.dispose();
  }
}
