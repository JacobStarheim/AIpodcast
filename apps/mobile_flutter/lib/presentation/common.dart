import 'package:flutter/material.dart';

import '../models.dart';
import 'app_theme.dart';
import 'formatting.dart';

class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color = AppColors.muted});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Text(text,
      style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          color: color));
}

class InlineProgress extends StatelessWidget {
  const InlineProgress(this.label, {super.key, this.color = AppColors.muted});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Row(children: [
          SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(label, style: TextStyle(color: color, fontSize: 12))),
        ]),
      );
}

class ErrorNotice extends StatelessWidget {
  const ErrorNotice(
      {super.key, required this.message, required this.onDismiss, this.onRetry});
  final String message;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
          decoration: BoxDecoration(
              color: AppColors.peach, borderRadius: BorderRadius.circular(18)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(message,
                          style: const TextStyle(fontSize: 13, height: 1.5)),
                      if (onRetry != null)
                        TextButton(
                            onPressed: onRetry, child: const Text('Try again')),
                    ],
                  ),
                ),
              ),
              IconButton(
                  tooltip: 'Dismiss message',
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 18)),
            ],
          ),
        ),
      );
}

/// A small pill describing whether an episode can answer questions.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});
  final TranscriptionStatus status;

  @override
  Widget build(BuildContext context) {
    final (background, foreground, icon) = switch (status) {
      TranscriptionStatus.ready => (
          AppColors.sage,
          AppColors.green,
          Icons.check_circle_outline_rounded
        ),
      TranscriptionStatus.pending => (
          AppColors.line,
          AppColors.muted,
          Icons.subtitles_off_outlined
        ),
      TranscriptionStatus.queued => (
          AppColors.peach,
          AppColors.orange,
          Icons.schedule_rounded
        ),
      TranscriptionStatus.processing => (
          AppColors.peach,
          AppColors.orange,
          Icons.autorenew_rounded
        ),
      TranscriptionStatus.failed => (
          AppColors.peach,
          AppColors.orange,
          Icons.error_outline_rounded
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: background, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (status.isInProgress)
          SizedBox.square(
              dimension: 10,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: foreground))
        else
          Icon(icon, size: 12, color: foreground),
        const SizedBox(width: 4),
        Flexible(
          child: Text(statusLabel(status),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: foreground)),
        ),
      ]),
    );
  }
}

void showReadingSheet(BuildContext context, String title, String body) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            24, 0, 24, 28 + MediaQuery.paddingOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 20),
            SelectableText(body, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 20),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done')),
          ],
        ),
      ),
    ),
  );
}

/// The app's logo: a small waveform on an orange tile.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) {
    final scale = size / 32;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: AppColors.orange,
            borderRadius: BorderRadius.circular(10 * scale)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [9.0, 18.0, 13.0, 7.0]
              .map((height) => Container(
                    width: 3 * scale,
                    height: height * scale,
                    margin: EdgeInsets.symmetric(horizontal: 1.3 * scale),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3 * scale)),
                  ))
              .toList(),
        ),
      ),
    );
  }
}
