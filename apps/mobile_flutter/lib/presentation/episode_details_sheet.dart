import 'package:flutter/material.dart';

import '../models.dart';
import '../podcast_controller.dart';
import 'app_theme.dart';
import 'common.dart';
import 'formatting.dart';

void showEpisodeDetails(BuildContext context, PodcastController controller) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => EpisodeDetailsSheet(controller: controller),
  );
}

/// Summary, chapters (tap to play from there) and the episode notes.
class EpisodeDetailsSheet extends StatelessWidget {
  const EpisodeDetailsSheet({super.key, required this.controller});
  final PodcastController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final episode = controller.selectedEpisode?.episode;
          if (episode == null) return const SizedBox(height: 120);
          final notes = plainText(episode.description);
          final summary = episode.summary;
          final meta = [
            episode.sourceName,
            MaterialLocalizations.of(context)
                .formatMediumDate(episode.publishedAt.toLocal()),
            if (episode.durationSec != null)
              durationLabel(episode.durationSec!),
          ].where((part) => part.isNotEmpty).join('  ·  ');
          return ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .85),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  24, 0, 24, 28 + MediaQuery.paddingOf(context).bottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(episode.title,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(meta,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 13)),
                  if (summary != null) ...[
                    const SizedBox(height: 24),
                    const Eyebrow('SUMMARY'),
                    const SizedBox(height: 8),
                    SelectableText(summary,
                        style: Theme.of(context).textTheme.bodyLarge),
                  ],
                  if (episode.chapters.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Eyebrow('CHAPTERS'),
                    const SizedBox(height: 8),
                    for (final chapter in episode.chapters)
                      _ChapterTile(
                        chapter: chapter,
                        onTap: controller.canControlPlayback &&
                                episode.audioUrl.isNotEmpty
                            ? () {
                                controller.playSelectedEpisodeFrom(Duration(
                                    milliseconds:
                                        (chapter.startSec * 1000).round()));
                                Navigator.pop(context);
                              }
                            : null,
                      ),
                  ],
                  const SizedBox(height: 24),
                  const Eyebrow('EPISODE NOTES'),
                  const SizedBox(height: 8),
                  SelectableText(
                      notes.isEmpty
                          ? 'No episode notes are available for this recording.'
                          : notes,
                      style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 20),
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Done')),
                ],
              ),
            ),
          );
        },
      );
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({required this.chapter, required this.onTap});
  final Chapter chapter;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final start = timestampFromSeconds(chapter.startSec);
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: 'Play from $start: ${chapter.title}',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('chapter-${chapter.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.play_circle_outline_rounded,
                    size: 20, color: AppColors.green),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$start  ${chapter.title}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: AppColors.ink)),
                      if (chapter.summary.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(chapter.summary,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                height: 1.45,
                                color: AppColors.muted)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
