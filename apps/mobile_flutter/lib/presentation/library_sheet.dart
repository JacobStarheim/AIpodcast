import 'package:flutter/material.dart';

import '../models.dart';
import '../podcast_controller.dart';
import 'app_theme.dart';
import 'episode_art.dart';

class LibrarySheet extends StatefulWidget {
  const LibrarySheet({super.key, required this.controller});
  final PodcastController controller;

  @override
  State<LibrarySheet> createState() => _LibrarySheetState();
}

class _LibrarySheetState extends State<LibrarySheet> {
  String query = '';

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final episodes = controller.episodes
              .where((episode) => '${episode.title} ${episode.sourceName}'
                  .toLowerCase()
                  .contains(query.toLowerCase().trim()))
              .toList();
          final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
          final libraryError =
              controller.errorMessage?.startsWith('Failed to load') ?? false;
          return SizedBox(
            height: MediaQuery.sizeOf(context).height *
                (keyboardInset > 0 ? .96 : .8),
            child: Padding(
              padding: EdgeInsets.only(bottom: keyboardInset),
              child: CustomScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverToBoxAdapter(
                      child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 12, 16),
                    child: Row(children: [
                      Expanded(
                          child: Text('Your library',
                              style:
                                  Theme.of(context).textTheme.headlineSmall)),
                      IconButton(
                        tooltip: 'Refresh library',
                        onPressed: controller.isLoadingEpisodes
                            ? null
                            : controller.loadInitialEpisodes,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                      IconButton(
                        tooltip: 'Close library',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ]),
                  )),
                  SliverToBoxAdapter(
                      child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: TextField(
                      key: const ValueKey('episode-search'),
                      onChanged: (value) => setState(() => query = value),
                      decoration: const InputDecoration(
                        hintText: 'Find an episode or podcast',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                    ),
                  )),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  if (libraryError)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                        child: Semantics(
                          liveRegion: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'We couldn’t update your library. Check your connection and try again.',
                                style: TextStyle(color: AppColors.orange),
                              ),
                              TextButton(
                                onPressed: controller.isLoadingEpisodes ||
                                        controller.isLoadingMore
                                    ? null
                                    : () {
                                        controller.dismissError();
                                        if (controller.nextCursor != null &&
                                            controller.episodes.isNotEmpty) {
                                          controller.loadMoreEpisodes();
                                        } else {
                                          controller.loadInitialEpisodes();
                                        }
                                      },
                                child: const Text('Try again'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (controller.isLoadingEpisodes)
                    const SliverToBoxAdapter(
                        child: LinearProgressIndicator(minHeight: 2)),
                  if (episodes.isEmpty && !controller.isLoadingEpisodes)
                    SliverToBoxAdapter(
                        child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                          query.isEmpty
                              ? 'Your episodes will appear here.'
                              : 'No matching episodes in your loaded library.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.muted)),
                    )),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList.builder(
                      itemCount: episodes.length,
                      itemBuilder: (context, index) {
                        final episode = episodes[index];
                        final selected = episode.id ==
                            controller.selectedEpisode?.episode.id;
                        return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _LibraryEpisode(
                              episode: episode,
                              selected: selected,
                              onTap: controller.canSelectEpisode
                                  ? () {
                                      if (!selected) {
                                        controller.selectEpisode(episode.id);
                                      }
                                      Navigator.pop(context);
                                    }
                                  : null,
                            ));
                      },
                    ),
                  ),
                  if (controller.hasMoreEpisodes)
                    SliverToBoxAdapter(
                        child: _LoadMore(controller: controller)),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            ),
          );
        },
      );
}

class _LoadMore extends StatelessWidget {
  const _LoadMore({required this.controller});
  final PodcastController controller;
  @override
  Widget build(BuildContext context) => TextButton(
        onPressed:
            controller.isLoadingMore ? null : controller.loadMoreEpisodes,
        child: Text(controller.isLoadingMore
            ? 'Loading more episodes…'
            : 'Load more episodes'),
      );
}

class _LibraryEpisode extends StatelessWidget {
  const _LibraryEpisode(
      {required this.episode, required this.selected, required this.onTap});
  final EpisodeSummary episode;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        selected: selected,
        label: '${episode.sourceName}. ${episode.title}. '
            '${switch (episode.transcriptionStatus) {
          TranscriptionStatus.ready => 'Ready to ask',
          TranscriptionStatus.pending => 'Preparing transcript',
          TranscriptionStatus.failed => 'Audio only',
        }}',
        onTap: onTap,
        excludeSemantics: true,
        child: Material(
          color: selected ? AppColors.sage : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  EpisodeArt(seed: episode.sourceName, size: 56),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(episode.sourceName,
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.muted)),
                        const SizedBox(height: 4),
                        Text(episode.title,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                height: 1.35)),
                        const SizedBox(height: 6),
                        Text(
                          '${MaterialLocalizations.of(context).formatMediumDate(episode.publishedAt.toLocal())}'
                          ' · ${switch (episode.transcriptionStatus) {
                            TranscriptionStatus.ready => 'Ready to ask',
                            TranscriptionStatus.pending =>
                              'Preparing transcript',
                            TranscriptionStatus.failed => 'Audio only',
                          }}',
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.check_circle_rounded,
                        color: AppColors.green, size: 20),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}
