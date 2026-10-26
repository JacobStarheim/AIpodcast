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

/// Whole minutes such as `42 min` or `2 h 5 min`.
String minutesLabel(double minutes) {
  if (minutes < 1) return 'under 1 min';
  final whole = minutes.floor();
  if (whole < 60) return '$whole min';
  final rest = whole % 60;
  return rest == 0 ? '${whole ~/ 60} h' : '${whole ~/ 60} h $rest min';
}

/// Today's remaining transcription time, e.g. for Transcribe buttons.
String usageLabel(TranscriptionUsage usage) => usage.isUsedUp
    ? 'Today’s transcription limit is used up.'
    : '${minutesLabel(usage.remainingMinutes)} of ${minutesLabel(usage.limitMinutes)} transcription time left today.';

/// `just now`, `5 min ago`, `3 h ago`, else null (show a date instead).
String? recentLabel(DateTime time, DateTime now) {
  final elapsed = now.difference(time);
  if (elapsed.isNegative || elapsed < const Duration(minutes: 1)) {
    return 'just now';
  }
  if (elapsed < const Duration(hours: 1)) return '${elapsed.inMinutes} min ago';
  if (elapsed < const Duration(hours: 24)) return '${elapsed.inHours} h ago';
  return null;
}
