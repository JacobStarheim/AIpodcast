import 'package:flutter/material.dart';

import '../models.dart';
import '../podcast_controller.dart';
import '../sources_controller.dart';
import 'app_theme.dart';
import 'common.dart';
import 'episode_art.dart';
import 'formatting.dart';

class LibrarySheet extends StatefulWidget {
  const LibrarySheet(
      {super.key, required this.controller, required this.onAddPodcast});
  final PodcastController controller;
  final VoidCallback onAddPodcast;

  @override
  State<LibrarySheet> createState() => _LibrarySheetState();
}

class _LibrarySheetState extends State<LibrarySheet> {
  late final TextEditingController search =
      TextEditingController(text: widget.controller.libraryQuery);

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation:
            Listenable.merge([widget.controller, widget.controller.sources]),
        builder: (context, _) {
          final controller = widget.controller;
          final episodes = controller.episodes;
          final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
          final error = controller.error;
          final filteredSource = controller.sourceFilter == null
              ? null
              : controller.sources.sourceById(controller.sourceFilter!);
          final usage = controller.usage;
          final libraryError = error != null &&
              (error.kind == ErrorKind.library ||
                  error.kind == ErrorKind.transcription);
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
                        tooltip: 'Add podcast',
                        onPressed: widget.onAddPodcast,
                        icon: const Icon(Icons.add_rounded),
                      ),
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
                      controller: search,
                      onChanged: controller.setLibraryQuery,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: 'Find an episode',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                    ),
                  )),
                  SliverToBoxAdapter(child: _Filters(controller: controller)),
                  if (filteredSource != null)
                    SliverToBoxAdapter(
                      child: PodcastSettingsCard(
                          source: filteredSource, sources: controller.sources),
                    ),
                  if (usage != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                                usage.isUsedUp
                                    ? Icons.hourglass_empty_rounded
                                    : Icons.hourglass_bottom_rounded,
                                size: 14,
                                color: usage.isUsedUp
                                    ? AppColors.orange
                                    : AppColors.muted),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(usageLabel(usage),
                                  key: const ValueKey('library-usage'),
                                  style: TextStyle(
                                      fontSize: 12,
                                      height: 1.4,
                                      color: usage.isUsedUp
                                          ? AppColors.orange
                                          : AppColors.muted)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                      child: _ImportNotices(controller: controller)),
                  if (libraryError)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                        child: Semantics(
                          liveRegion: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(error.message,
                                  style:
                                      const TextStyle(color: AppColors.orange)),
                              Wrap(spacing: 8, children: [
                                if (error.kind == ErrorKind.library)
                                  TextButton(
                                    onPressed: controller.isLoadingEpisodes ||
                                            controller.isLoadingMore
                                        ? null
                                        : () {
                                            controller.dismissError();
                                            if (controller.nextCursor != null &&
                                                episodes.isNotEmpty) {
                                              controller.loadMoreEpisodes();
                                            } else {
                                              controller.loadInitialEpisodes();
                                            }
                                          },
                                    child: const Text('Try again'),
                                  ),
                                TextButton(
                                  onPressed: controller.dismissError,
                                  child: const Text('Dismiss'),
                                ),
                              ]),
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
                          controller.hasLibraryFilter
                              ? 'No episodes match these filters.'
                              : 'Your episodes will appear here. Add a podcast to get started.',
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
                              requesting: controller
                                  .isTranscriptionRequested(episode.id),
                              onTranscribe: () =>
                                  controller.requestTranscription(episode.id),
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

/// "Only ready" and one chip per podcast, scrolling sideways.
class _Filters extends StatelessWidget {
  const _Filters({required this.controller});
  final PodcastController controller;

  @override
  Widget build(BuildContext context) {
    final sources = controller.sources.items;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      child: Row(children: [
        FilterChip(
          key: const ValueKey('filter-ready'),
          label: const Text('Only ready'),
          selected: controller.onlyReady,
          onSelected: controller.setOnlyReady,
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 24, color: AppColors.line),
        const SizedBox(width: 12),
        ChoiceChip(
          key: const ValueKey('filter-all-podcasts'),
          label: const Text('All podcasts'),
          selected: controller.sourceFilter == null,
          onSelected: (_) => controller.setSourceFilter(null),
        ),
        for (final source in sources) ...[
          const SizedBox(width: 8),
          ChoiceChip(
            key: ValueKey('filter-source-${source.id}'),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(source.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            selected: controller.sourceFilter == source.id,
            onSelected: (_) => controller.setSourceFilter(
                controller.sourceFilter == source.id ? null : source.id),
          ),
        ],
      ]),
    );
  }
}

/// Settings of the podcast the library is filtered by: automatic
/// transcription of new episodes, and when the feed was last checked.
class PodcastSettingsCard extends StatelessWidget {
  const PodcastSettingsCard(
      {super.key, required this.source, required this.sources});
  final SourceSummary source;
  final SourcesController sources;

  @override
  Widget build(BuildContext context) {
    final saving = sources.isSavingSettings(source.id);
    final error = sources.settingsErrors[source.id];
    final refreshed = source.lastRefreshedAt?.toLocal();
    final checked = refreshed == null
        ? 'Not checked for new episodes yet.'
        : 'Checked for new episodes ${recentLabel(refreshed, DateTime.now()) ?? 'on ${MaterialLocalizations.of(context).formatMediumDate(refreshed)}'}.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      // A Material, so the switch's ink shows on the tinted card.
      child: Material(
        color: AppColors.sage,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(source.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14)),
              SwitchListTile(
                key: ValueKey('auto-transcribe-${source.id}'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Transcribe new episodes automatically',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: const Text(
                    'New episodes are transcribed automatically, within the daily limit.',
                    style: TextStyle(fontSize: 12, color: AppColors.muted)),
                value: source.autoTranscribe,
                onChanged: saving
                    ? null
                    : (value) => sources.setAutoTranscribe(source.id, value),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(checked,
                    style:
                        const TextStyle(fontSize: 12, color: AppColors.muted)),
              ),
              if (error != null) ...[
                const SizedBox(height: 6),
                Semantics(
                  liveRegion: true,
                  child: Text(error,
                      key: ValueKey('auto-transcribe-error-${source.id}'),
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.orange)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Podcasts whose episode list is still importing, or failed to import.
class _ImportNotices extends StatelessWidget {
  const _ImportNotices({required this.controller});
  final PodcastController controller;

  @override
  Widget build(BuildContext context) {
    final sources = controller.sources;
    bool noteworthy(SourceSummary source) {
      final recent = sources.recentlyAdded.contains(source.id);
      final status = source.lastJob?.status;
      if (status == null) return recent && source.episodeCount == 0;
      return status.isInProgress ||
          (status == IngestJobStatus.failed && recent);
    }

    final notices = sources.items.where(noteworthy).toList();
    if (notices.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Column(children: [
        for (final source in notices)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SourceImportStatus(source: source, showName: true),
          ),
      ]),
    );
  }
}

/// One line describing a podcast's latest import.
class SourceImportStatus extends StatelessWidget {
  const SourceImportStatus(
      {super.key, required this.source, this.showName = false});
  final SourceSummary source;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final job = source.lastJob;
    final status = job?.status ?? IngestJobStatus.queued;
    final failed = status == IngestJobStatus.failed;
    final name = showName ? '${source.name}: ' : '';
    final text = switch (status) {
      IngestJobStatus.queued => '${name}Waiting to import episodes…',
      IngestJobStatus.processing => '${name}Importing episodes…',
      IngestJobStatus.failed => job?.error == null
          ? '${name}The feed couldn’t be imported.'
          : '${name}Import failed: ${job!.error}',
      IngestJobStatus.completed ||
      IngestJobStatus.unknown =>
        '$name${source.episodeCount} ${source.episodeCount == 1 ? 'episode' : 'episodes'} in your library',
    };
    return Semantics(
      liveRegion: true,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (status.isInProgress)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5)),
          )
        else
          Icon(
              failed
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              size: 14,
              color: failed ? AppColors.orange : AppColors.green),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: failed ? AppColors.orange : AppColors.muted)),
        ),
      ]),
    );
  }
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
  const _LibraryEpisode({
    required this.episode,
    required this.selected,
    required this.requesting,
    required this.onTranscribe,
    required this.onTap,
  });
  final EpisodeSummary episode;
  final bool selected;
  final bool requesting;
  final VoidCallback onTranscribe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final status = episode.transcriptionStatus;
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(episode.publishedAt.toLocal());
    final duration = episode.durationSec;
    final failure = status == TranscriptionStatus.failed
        ? episode.transcriptionError
        : null;
    return Material(
      color: selected ? AppColors.sage : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            enabled: onTap != null,
            selected: selected,
            label: '${episode.sourceName}. ${episode.title}. '
                '${duration != null ? '${durationLabel(duration)}. ' : ''}'
                '${statusLabel(status)}',
            onTap: onTap,
            excludeSemantics: true,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PodcastArtwork(
                        imageUrl: episode.imageUrl,
                        seed: episode.sourceName,
                        size: 56),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(episode.sourceName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.muted)),
                          const SizedBox(height: 4),
                          Text(episode.title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  height: 1.35)),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                  duration == null
                                      ? date
                                      : '$date · ${durationLabel(duration)}',
                                  style: const TextStyle(
                                      fontSize: 11, color: AppColors.muted)),
                              StatusBadge(status: status),
                            ],
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
          if (failure != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(84, 0, 14, 4),
              child: Text(failure,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, height: 1.4, color: AppColors.orange)),
            ),
          if (status.canRequestTranscription)
            Padding(
              padding: const EdgeInsets.fromLTRB(76, 0, 8, 6),
              child: Semantics(
                button: true,
                enabled: !requesting,
                label: requesting
                    ? 'Requesting transcription of ${episode.title}'
                    : 'Transcribe ${episode.title}',
                onTap: requesting ? null : onTranscribe,
                excludeSemantics: true,
                child: TextButton.icon(
                  key: ValueKey('transcribe-${episode.id}'),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.green,
                      minimumSize: const Size(48, 48)),
                  onPressed: requesting ? null : onTranscribe,
                  icon: requesting
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5))
                      : const Icon(Icons.subtitles_outlined, size: 18),
                  label: Text(requesting
                      ? 'Requesting…'
                      : status == TranscriptionStatus.failed
                          ? 'Try again'
                          : 'Transcribe'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
