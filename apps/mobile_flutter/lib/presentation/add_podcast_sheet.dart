import 'package:flutter/material.dart';

import '../models.dart';
import '../sources_controller.dart';
import 'app_theme.dart';
import 'episode_art.dart';
import 'library_sheet.dart' show SourceImportStatus;

void showAddPodcastSheet(BuildContext context, SourcesController sources) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => AddPodcastSheet(sources: sources),
  );
}

/// Search the podcast directory or paste a feed link, then follow the import.
class AddPodcastSheet extends StatefulWidget {
  const AddPodcastSheet({super.key, required this.sources});
  final SourcesController sources;

  @override
  State<AddPodcastSheet> createState() => _AddPodcastSheetState();
}

class _AddPodcastSheetState extends State<AddPodcastSheet> {
  late final TextEditingController search =
      TextEditingController(text: widget.sources.searchQuery);
  final rss = TextEditingController();
  bool showRss = false;
  String? pastedSourceId;

  @override
  void dispose() {
    search.dispose();
    rss.dispose();
    super.dispose();
  }

  Future<void> _addRss() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final source = await widget.sources.addPodcast(rssUrl: rss.text);
    if (!mounted || source == null) return;
    setState(() => pastedSourceId = source.id);
    rss.clear();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.sources,
        builder: (context, _) {
          final sources = widget.sources;
          final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
          final query = sources.searchQuery;
          final pasted =
              pastedSourceId == null ? null : sources.sourceById(pastedSourceId!);
          return SizedBox(
            height: MediaQuery.sizeOf(context).height *
                (keyboardInset > 0 ? .96 : .85),
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
                          child: Text('Add a podcast',
                              style:
                                  Theme.of(context).textTheme.headlineSmall),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ]),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TextField(
                        key: const ValueKey('podcast-search'),
                        controller: search,
                        onChanged: sources.search,
                        textInputAction: TextInputAction.search,
                        decoration: const InputDecoration(
                          hintText: 'Search podcasts',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 24, 0),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          key: const ValueKey('paste-rss'),
                          style: TextButton.styleFrom(
                              foregroundColor: AppColors.green,
                              minimumSize: const Size(48, 48)),
                          onPressed: () => setState(() => showRss = !showRss),
                          icon: Icon(
                              showRss
                                  ? Icons.expand_less_rounded
                                  : Icons.rss_feed_rounded,
                              size: 18),
                          label: const Text('Paste RSS link'),
                        ),
                      ),
                    ),
                  ),
                  if (showRss)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              key: const ValueKey('rss-url'),
                              controller: rss,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _addRss(),
                              decoration: const InputDecoration(
                                hintText: 'https://example.com/feed.xml',
                                labelText: 'RSS feed link',
                              ),
                            ),
                            const SizedBox(height: 8),
                            ValueListenableBuilder<TextEditingValue>(
                              valueListenable: rss,
                              builder: (context, value, _) {
                                final adding = sources.isAdding(value.text);
                                return FilledButton.icon(
                                  key: const ValueKey('add-rss'),
                                  onPressed:
                                      value.text.trim().isEmpty || adding
                                          ? null
                                          : _addRss,
                                  icon: const Icon(Icons.add_rounded),
                                  label: Text(adding ? 'Adding…' : 'Add feed'),
                                );
                              },
                            ),
                            if (pasted != null) ...[
                              const SizedBox(height: 10),
                              Text(pasted.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                              const SizedBox(height: 4),
                              SourceImportStatus(source: pasted),
                            ],
                          ],
                        ),
                      ),
                    ),
                  if (sources.addError != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 4, 12, 4),
                        child: Semantics(
                          liveRegion: true,
                          child: Row(children: [
                            Expanded(
                              child: Text(sources.addError!,
                                  style: const TextStyle(
                                      color: AppColors.orange, fontSize: 13)),
                            ),
                            IconButton(
                              tooltip: 'Dismiss message',
                              onPressed: sources.dismissAddError,
                              icon: const Icon(Icons.close_rounded, size: 18),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  if (sources.isSearching)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    )
                  else if (sources.searchError != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                        child: Text(sources.searchError!,
                            style: const TextStyle(color: AppColors.orange)),
                      ),
                    )
                  else if (query.length >= SourcesController.minimumQueryLength &&
                      sources.results.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(28),
                        child: Text('No podcasts with a feed match that search.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.muted)),
                      ),
                    )
                  else if (query.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(24, 12, 24, 0),
                        child: Text(
                            'Search by title or host. New podcasts are added with their episode list; transcribe the episodes you want to ask about.',
                            style: TextStyle(
                                color: AppColors.muted, fontSize: 13)),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList.builder(
                      itemCount: sources.results.length,
                      itemBuilder: (context, index) => _SearchResult(
                        result: sources.results[index],
                        sources: sources,
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            ),
          );
        },
      );
}

class _SearchResult extends StatelessWidget {
  const _SearchResult({required this.result, required this.sources});
  final PodcastSearchResult result;
  final SourcesController sources;

  @override
  Widget build(BuildContext context) {
    final source = sources.sourceForFeed(result.feedUrl);
    final adding = sources.isAdding(result.feedUrl);
    final details = [
      if (result.author != null) result.author!,
      if (result.genre != null) result.genre!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PodcastArtwork(
              imageUrl: result.imageUrl, seed: result.title, size: 56),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14, height: 1.35)),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(details,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.muted)),
                ],
                const SizedBox(height: 6),
                if (source != null)
                  SourceImportStatus(source: source)
                else
                  Semantics(
                    button: true,
                    enabled: !adding,
                    label: adding
                        ? 'Adding ${result.title}'
                        : 'Add ${result.title}',
                    onTap: adding
                        ? null
                        : () => sources.addPodcast(
                              rssUrl: result.feedUrl,
                              name: result.title,
                              imageUrl: result.imageUrl,
                            ),
                    excludeSemantics: true,
                    child: OutlinedButton.icon(
                      key: ValueKey('add-${result.feedUrl}'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.green,
                        minimumSize: const Size(48, 40),
                        side: const BorderSide(color: AppColors.line),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: adding
                          ? null
                          : () => sources.addPodcast(
                                rssUrl: result.feedUrl,
                                name: result.title,
                                imageUrl: result.imageUrl,
                              ),
                      icon: adding
                          ? const SizedBox.square(
                              dimension: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 1.5))
                          : const Icon(Icons.add_rounded, size: 18),
                      label: Text(adding ? 'Adding…' : 'Add'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
