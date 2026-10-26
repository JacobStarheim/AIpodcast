import '../models.dart';

/// `m:ss`, or `h:mm:ss` from one hour.
String formatTimestamp(Duration duration) {
  final total = duration.inSeconds.clamp(0, 359999);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

String timestampFromSeconds(double seconds) =>
    formatTimestamp(Duration(milliseconds: (seconds * 1000).round()));

/// A rounded length such as `45 sec`, `12 min` or `1 h 5 min`.
String durationLabel(int seconds) {
  if (seconds < 60) return '$seconds sec';
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return '$minutes min';
  final rest = minutes % 60;
  return rest == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h $rest min';
}

String statusLabel(TranscriptionStatus status) => switch (status) {
      TranscriptionStatus.ready => 'Ready to ask',
      TranscriptionStatus.pending => 'Not transcribed',
      TranscriptionStatus.queued => 'Queued',
      TranscriptionStatus.processing => 'Transcribing',
      TranscriptionStatus.failed => 'Transcription failed',
    };

/// Plain text from HTML-ish feed descriptions.
String plainText(String value) => value
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
