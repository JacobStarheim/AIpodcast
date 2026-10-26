import 'package:flutter/material.dart';

import 'app_config.dart';
import 'audio_output.dart';
import 'playback_position_store.dart';
import 'podcast_api.dart';
import 'podcast_controller.dart';
import 'presentation/add_podcast_sheet.dart';
import 'presentation/app_theme.dart';
import 'presentation/common.dart';
import 'presentation/composer.dart';
import 'presentation/conversation_view.dart';
import 'presentation/episode_card.dart';
import 'presentation/episode_details_sheet.dart';
import 'presentation/library_sheet.dart';
import 'voice_recorder.dart';

void main() => runApp(const PodcastVoiceApp());

class PodcastVoiceApp extends StatelessWidget {
  const PodcastVoiceApp({super.key, this.controller});
  final PodcastController? controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Podcast',
        debugShowCheckedModeBanner: false,
        theme: podcastTheme(),
        home: PodcastHomePage(controller: controller),
      );
}

class PodcastHomePage extends StatefulWidget {
  const PodcastHomePage({super.key, this.controller});
  final PodcastController? controller;

  @override
  State<PodcastHomePage> createState() => _PodcastHomePageState();
}

class _PodcastHomePageState extends State<PodcastHomePage>
    with WidgetsBindingObserver {
  late final PodcastController controller;
  final questionController = TextEditingController();
  final questionFocus = FocusNode();
  final newestTurnKey = GlobalKey();
  ConversationTurn? _newestTurn;
  QuestionScope? _newestScope;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ??
        PodcastController(
          api: HttpPodcastApi(baseUrl: apiBaseUrl, apiKey: apiKey),
          recorder: RecordVoiceRecorder(),
          audioOutput: JustAudioOutput(),
          positionStore: SharedPreferencesPositionStore(),
        );
    _newestScope = controller.scope;
    controller.addListener(_onUpdate);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => controller.loadInitialEpisodes());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      controller.savePlaybackPosition();
    }
  }

  void _onUpdate() {
    if (!mounted) return;
    final turns = controller.conversation;
    final newest = turns.isEmpty ? null : turns.last;
    // Switching scope shows another conversation; that is not a new answer.
    final hasNewAnswer = newest != null &&
        !identical(newest, _newestTurn) &&
        controller.scope == _newestScope;
    _newestTurn = newest;
    _newestScope = controller.scope;
    if (hasNewAnswer && questionController.text.trim() == newest.question) {
      // Retain the draft when the request fails; clear it once answered.
      questionController.clear();
    }
    setState(() {});
    if (hasNewAnswer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final answerContext = newestTurnKey.currentContext;
        if (!mounted || answerContext == null) return;
        Scrollable.ensureVisible(answerContext,
            alignment: .08,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 280));
      });
    }
  }

  Future<void> _submit([String? suggestion]) async {
    final question = (suggestion ?? questionController.text).trim();
    if (question.isEmpty || !controller.canAskQuestion) return;
    if (suggestion != null) questionController.text = suggestion;
    questionFocus.unfocus();
    await controller.submitTypedQuestion(question);
  }

  void _openLibrary() {
    questionFocus.unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => LibrarySheet(
          controller: controller, onAddPodcast: _openAddPodcast),
    );
  }

  void _openAddPodcast() {
    questionFocus.unfocus();
    showAddPodcastSheet(context, controller.sources);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_onUpdate);
    controller.close();
    controller.dispose();
    questionController.dispose();
    questionFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final episode = controller.selectedEpisode?.episode;
    final error = controller.error;
    // List errors belong to the library sheet once an episode is showing.
    final showError = error != null &&
        !error.belongsToConversation &&
        (error.kind != ErrorKind.library || episode == null);
    final loading = controller.isSelectingEpisode ||
        (episode == null && controller.isLoadingEpisodes);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              children: [
                _Header(
                    onLibrary:
                        controller.canSelectEpisode ? _openLibrary : null),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: controller.loadInitialEpisodes,
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(24, 10, 24, 28),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Listen closer.',
                              style: Theme.of(context).textTheme.headlineLarge),
                          const SizedBox(height: 8),
                          const Text('Good stories. Better conversations.',
                              style: TextStyle(color: AppColors.muted)),
                          const SizedBox(height: 24),
                          if (showError) ...[
                            ErrorNotice(
                              message: error.message,
                              onDismiss: controller.dismissError,
                              onRetry: error.kind == ErrorKind.library &&
                                      controller.canSelectEpisode &&
                                      episode == null
                                  ? controller.loadInitialEpisodes
                                  : null,
                            ),
                            const SizedBox(height: 16),
                          ],
                          if (loading)
                            const _LoadingEpisode()
                          else if (episode != null)
                            EpisodeCard(
                              controller: controller,
                              onDetails: () =>
                                  showEpisodeDetails(context, controller),
                            )
                          else
                            _EmptyLibrary(
                              onRefresh: controller.loadInitialEpisodes,
                              hasEpisodes: controller.episodes.isNotEmpty,
                              onLibrary: _openLibrary,
                              onAddPodcast: _openAddPodcast,
                            ),
                          const SizedBox(height: 26),
                          if (episode != null || controller.hasReadyEpisodes)
                            ConversationSection(
                              controller: controller,
                              onAsk: _submit,
                              newestTurnKey: newestTurnKey,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: Composer(
        controller: controller,
        textController: questionController,
        focusNode: questionFocus,
        onSubmit: _submit,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onLibrary});
  final VoidCallback? onLibrary;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 16, 8),
        child: Row(children: [
          const _BrandMark(),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('podcast',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.9)),
          ),
          IconButton(
              tooltip: 'Browse episodes',
              onPressed: onLibrary,
              icon: const Icon(Icons.library_music_outlined, size: 25)),
        ]),
      );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
              color: AppColors.orange, borderRadius: BorderRadius.circular(10)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [9.0, 18.0, 13.0, 7.0]
                .map((height) => Container(
                      width: 3,
                      height: height,
                      margin: const EdgeInsets.symmetric(horizontal: 1.3),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(3)),
                    ))
                .toList(),
          ),
        ),
      );
}

class _LoadingEpisode extends StatelessWidget {
  const _LoadingEpisode();
  @override
  Widget build(BuildContext context) => Container(
        height: 180,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: AppColors.sage, borderRadius: BorderRadius.circular(26)),
        child: const Padding(
            padding: EdgeInsets.all(28),
            child: InlineProgress('Getting your episodes ready…')),
      );
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({
    required this.onRefresh,
    required this.hasEpisodes,
    required this.onLibrary,
    required this.onAddPodcast,
  });
  final VoidCallback onRefresh;
  final bool hasEpisodes;
  final VoidCallback onLibrary;
  final VoidCallback onAddPodcast;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
            color: AppColors.sage, borderRadius: BorderRadius.circular(26)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.headphones_rounded,
                color: AppColors.green, size: 38),
            const SizedBox(height: 20),
            Text(
                hasEpisodes
                    ? 'Choose your next listen.'
                    : 'Your next listen starts here.',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            Text(
                hasEpisodes
                    ? 'Open your library and choose an episode to explore.'
                    : 'Add a podcast to bring in its episodes, or refresh to check for new arrivals.',
                style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 18),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: hasEpisodes ? onLibrary : onAddPodcast,
                icon: Icon(hasEpisodes
                    ? Icons.library_music_outlined
                    : Icons.add_rounded),
                label: Text(hasEpisodes ? 'Open library' : 'Add a podcast'),
              ),
              if (!hasEpisodes)
                TextButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Refresh library'),
                ),
            ]),
          ],
        ),
      );
}
