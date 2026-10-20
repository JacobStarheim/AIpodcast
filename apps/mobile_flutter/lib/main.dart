import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'audio_output.dart';
import 'models.dart';
import 'podcast_api.dart';
import 'podcast_controller.dart';
import 'presentation/app_theme.dart';
import 'presentation/episode_art.dart';
import 'presentation/library_sheet.dart';
import 'voice_recorder.dart';

const String configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');

String get apiBaseUrl => configuredApiBaseUrl.isNotEmpty
    ? configuredApiBaseUrl
    : defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:4000'
        : 'http://localhost:4000';

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

class _PodcastHomePageState extends State<PodcastHomePage> {
  late final PodcastController controller;
  final questionController = TextEditingController();
  final questionFocus = FocusNode();
  final answerKey = GlobalKey();
  QaResponse? _lastResponse;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ??
        PodcastController(
          api: HttpPodcastApi(baseUrl: apiBaseUrl),
          recorder: RecordVoiceRecorder(),
          audioOutput: JustAudioOutput(),
        );
    controller.addListener(_onUpdate);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => controller.loadInitialEpisodes());
  }

  void _onUpdate() {
    if (!mounted) return;
    final response = controller.latestResponse;
    final hasNewAnswer =
        response != null && !identical(response, _lastResponse);
    _lastResponse = response;
    if (hasNewAnswer &&
        questionController.text.trim() == controller.lastQuestionText) {
      questionController.clear();
    }
    setState(() {});
    if (hasNewAnswer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final answerContext = answerKey.currentContext;
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
    // Retain the draft for retry when the request fails.
    if (mounted &&
        controller.latestResponse != null &&
        questionController.text.trim() == question) {
      questionController.clear();
    }
  }

  void _openLibrary() {
    questionFocus.unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => LibrarySheet(controller: controller),
    );
  }

  @override
  void dispose() {
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
                          if (controller.errorMessage != null &&
                              controller.latestResponse == null) ...[
                            _ErrorNotice(
                              message: controller.errorMessage!,
                              onDismiss: controller.dismissError,
                              onRetry:
                                  controller.canSelectEpisode && episode == null
                                      ? controller.loadInitialEpisodes
                                      : null,
                            ),
                            const SizedBox(height: 16),
                          ],
                          if (controller.isLoadingEpisodes ||
                              controller.isSelectingEpisode)
                            const _LoadingEpisode()
                          else if (episode != null)
                            _EpisodeCard(
                              episode: episode,
                              status: controller
                                  .selectedEpisode!.transcriptionStatus,
                              controller: controller,
                            )
                          else
                            _EmptyLibrary(
                              onRefresh: controller.loadInitialEpisodes,
                              hasEpisodes: controller.episodes.isNotEmpty,
                              onLibrary: _openLibrary,
                            ),
                          const SizedBox(height: 26),
                          if (episode != null) ...[
                            if (controller.latestResponse != null)
                              _AnswerSection(
                                  key: answerKey, controller: controller)
                            else if (controller.voiceState ==
                                VoiceState.processing)
                              _WorkingAnswer(
                                  question: controller.lastQuestionText)
                            else
                              _QuestionIdeas(
                                enabled: controller.canAskQuestion,
                                onAsk: _submit,
                                ready: controller.isEpisodeReady,
                              ),
                          ],
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
      bottomNavigationBar: _Composer(
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

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard(
      {required this.episode, required this.status, required this.controller});
  final EpisodeDetail episode;
  final TranscriptionStatus status;
  final PodcastController controller;

  @override
  Widget build(BuildContext context) {
    final isPlaying = controller.isPlayingEpisode;
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(episode.publishedAt.toLocal());
    final duration = episode.durationSec;
    return Container(
      decoration: BoxDecoration(
          color: AppColors.ink, borderRadius: BorderRadius.circular(26)),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.graphic_eq_rounded,
                size: 16, color: Color(0xFFC7D8BD)),
            const SizedBox(width: 7),
            const Expanded(
                child: Text('IN FOCUS',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.8,
                        color: Color(0xFFC7D8BD)))),
            Expanded(
                child: Text(
                    switch (status) {
                      TranscriptionStatus.ready => 'Ready to ask',
                      TranscriptionStatus.pending => 'Preparing',
                      TranscriptionStatus.failed => 'Audio only',
                    },
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                        color: Color(0xFFDCE9D5), fontSize: 11))),
          ]),
          const SizedBox(height: 20),
          LayoutBuilder(builder: (context, constraints) {
            final compact = constraints.maxWidth < 290 ||
                MediaQuery.textScalerOf(context).scale(16) > 24;
            final title = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(episode.sourceName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFFC7D0C8), fontSize: 12, height: 1.4)),
                const SizedBox(height: 7),
                Text(episode.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        height: 1.22,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.5)),
              ],
            );
            if (compact) return title;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                EpisodeArt(seed: episode.sourceName, size: 86),
                const SizedBox(width: 16),
                Expanded(child: title),
              ],
            );
          }),
          const SizedBox(height: 18),
          Text(
              '$date${duration != null ? '  ·  ${_durationLabel(duration)}' : ''}',
              style: const TextStyle(color: Color(0xFFB9C4BA), fontSize: 12)),
          if (status != TranscriptionStatus.ready) ...[
            const SizedBox(height: 12),
            Text(
                status == TranscriptionStatus.pending
                    ? 'Your transcript is on its way. You can listen while you wait.'
                    : 'The transcript isn’t available yet. You can still listen to this episode.',
                style: const TextStyle(color: Color(0xFFD9DED5), fontSize: 13)),
          ],
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('play-episode'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDCE9D5),
                  foregroundColor: AppColors.ink,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                ),
                onPressed: isPlaying
                    ? controller.stopAudio
                    : controller.voiceState == VoiceState.idle &&
                            episode.audioUrl.isNotEmpty
                        ? controller.playSelectedEpisode
                        : null,
                icon: Icon(
                    isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    size: 24),
                label: Text(isPlaying ? 'Stop listening' : 'Play episode'),
              ),
            ),
            const SizedBox(width: 10),
            IconButton(
              tooltip: 'Episode details',
              style: IconButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF536056))),
              onPressed: () => _showDetails(context, episode),
              icon: const Icon(Icons.notes_rounded, size: 21),
            ),
          ]),
        ],
      ),
    );
  }
}

class _QuestionIdeas extends StatelessWidget {
  const _QuestionIdeas(
      {required this.enabled, required this.onAsk, required this.ready});
  final bool enabled;
  final bool ready;
  final ValueChanged<String> onAsk;
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              ready
                  ? 'Follow your curiosity.'
                  : 'A little more listening, first.',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
              ready
                  ? 'Ask about this episode. Every answer links back to what was said.'
                  : 'Questions will be available once the transcript is ready.',
              style: const TextStyle(
                  color: AppColors.muted, fontSize: 14, height: 1.5)),
          if (ready) ...[
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _Suggestion(
                  label: 'The big picture',
                  icon: Icons.auto_awesome_outlined,
                  onTap: enabled
                      ? () => onAsk('What is this episode about?')
                      : null),
              _Suggestion(
                  label: 'Key takeaways',
                  icon: Icons.lightbulb_outline_rounded,
                  onTap: enabled
                      ? () =>
                          onAsk('What are the key takeaways from this episode?')
                      : null),
            ]),
          ],
        ],
      );
}

class _Suggestion extends StatelessWidget {
  const _Suggestion({required this.label, required this.icon, this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          minimumSize: const Size(48, 48),
          side: const BorderSide(color: AppColors.line),
          backgroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 17, color: AppColors.orange),
        label: Text(label, style: const TextStyle(fontSize: 13)),
      );
}

class _AnswerSection extends StatelessWidget {
  const _AnswerSection({super.key, required this.controller});
  final PodcastController controller;
  @override
  Widget build(BuildContext context) {
    final response = controller.latestResponse!;
    final question = controller.lastQuestionText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (question != null) ...[
          const _Eyebrow('YOUR QUESTION'),
          const SizedBox(height: 8),
          Text(question, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 20),
        ],
        if (controller.errorMessage != null) ...[
          _ErrorNotice(
            message: controller.errorMessage!,
            onDismiss: controller.dismissError,
          ),
          const SizedBox(height: 16),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(22)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(
                    response.grounded
                        ? Icons.verified_outlined
                        : Icons.info_outline_rounded,
                    color:
                        response.grounded ? AppColors.green : AppColors.orange,
                    size: 20),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        response.grounded
                            ? 'From this episode'
                            : 'Not covered in this episode',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14))),
              ]),
              const SizedBox(height: 14),
              SelectableText(
                  response.grounded
                      ? response.answerText
                      : 'I couldn’t find enough detail in the transcript to answer that. Try asking about a topic discussed in this episode.',
                  style: const TextStyle(
                      fontSize: 16, height: 1.6, color: AppColors.ink)),
              if (response.grounded &&
                  controller.voiceState == VoiceState.processing) ...[
                const SizedBox(height: 14),
                const _InlineProgress('Preparing spoken answer…'),
              ],
              if (response.citations.isNotEmpty) ...[
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Divider(height: 1)),
                const _Eyebrow('HEAR IT IN CONTEXT'),
                const SizedBox(height: 12),
                for (var index = 0;
                    index < response.citations.length;
                    index++) ...[
                  if (index > 0) const SizedBox(height: 12),
                  _CitationCard(
                      citation: response.citations[index],
                      controller: controller),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CitationCard extends StatelessWidget {
  const _CitationCard({required this.citation, required this.controller});
  final Citation citation;
  final PodcastController controller;
  @override
  Widget build(BuildContext context) {
    final active = controller.activeCitationId == citation.segmentId;
    final enabled = controller.voiceState == VoiceState.idle ||
        controller.voiceState == VoiceState.speaking;
    return Material(
      color: active ? AppColors.peach : AppColors.sage,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled
            ? () => active
                ? controller.stopAudio()
                : controller.playCitation(citation)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(citation.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, height: 1.5, color: AppColors.green)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: AppColors.green,
                      minimumSize: const Size(48, 48),
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: enabled
                        ? () => active
                            ? controller.stopAudio()
                            : controller.playCitation(citation)
                        : null,
                    icon: Icon(
                        active
                            ? Icons.stop_circle_outlined
                            : Icons.play_circle_outline_rounded,
                        size: 25),
                    label: Text(
                        active
                            ? 'Stop audio'
                            : 'Listen from ${_timestamp(citation.startSec)}',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
                IconButton(
                  tooltip: 'Read full excerpt',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  padding: EdgeInsets.zero,
                  onPressed: () => _showExcerpt(context, citation),
                  icon: const Icon(Icons.open_in_full_rounded,
                      size: 16, color: AppColors.green),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer(
      {required this.controller,
      required this.textController,
      required this.focusNode,
      required this.onSubmit});
  final PodcastController controller;
  final TextEditingController textController;
  final FocusNode focusNode;
  final VoidCallback onSubmit;
  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DecoratedBox(
        decoration: const BoxDecoration(
            color: AppColors.paper,
            border: Border(top: BorderSide(color: AppColors.line))),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: textController,
                      builder: (context, value, _) => TextField(
                        key: const ValueKey('question-input'),
                        controller: textController,
                        focusNode: focusNode,
                        enabled: controller.canAskQuestion,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => onSubmit(),
                        minLines: 1,
                        maxLines: 2,
                        decoration: InputDecoration(
                          hintText: 'Ask about this episode…',
                          labelText: keyboardOpen ? 'Your question' : null,
                          suffixIcon: Padding(
                            padding: const EdgeInsets.all(5),
                            child: IconButton.filled(
                              key: const ValueKey('ask-question'),
                              tooltip: 'Ask question',
                              style: IconButton.styleFrom(
                                backgroundColor: AppColors.green,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: AppColors.sage,
                                disabledForegroundColor: AppColors.muted,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: controller.canAskQuestion &&
                                      value.text.trim().isNotEmpty
                                  ? onSubmit
                                  : null,
                              icon: const Icon(Icons.arrow_upward_rounded,
                                  size: 22),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (!keyboardOpen) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: _VoiceControl(controller: controller)),
                        const SizedBox(width: 8),
                        IconButton(
                          key: const ValueKey('read-answers-aloud'),
                          tooltip: controller.readAnswersAloud
                              ? 'Turn spoken answers off'
                              : 'Turn spoken answers on',
                          isSelected: controller.readAnswersAloud,
                          onPressed: controller.voiceState == VoiceState.idle
                              ? () => controller.setReadAnswersAloud(
                                  !controller.readAnswersAloud)
                              : null,
                          style: IconButton.styleFrom(
                            backgroundColor: controller.readAnswersAloud
                                ? AppColors.sage
                                : Colors.transparent,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.volume_off_outlined, size: 22),
                          selectedIcon:
                              const Icon(Icons.volume_up_outlined, size: 22),
                        ),
                      ]),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceControl extends StatelessWidget {
  const _VoiceControl({required this.controller});
  final PodcastController controller;
  @override
  Widget build(BuildContext context) {
    final state = controller.voiceState;
    final recording = state == VoiceState.recording;
    final starting = state == VoiceState.starting;
    final processing = state == VoiceState.processing;
    final playing = controller.canStopAudio;
    final label = switch (state) {
      VoiceState.starting => 'Opening microphone…',
      VoiceState.recording => 'Listening · tap to send',
      VoiceState.processing => controller.latestResponse != null
          ? 'Preparing audio…'
          : 'Finding an answer…',
      VoiceState.speaking => 'Stop spoken answer',
      VoiceState.idle => playing ? 'Stop audio' : 'Tap or hold to ask',
    };
    Future<void> onTap() async {
      FocusManager.instance.primaryFocus?.unfocus();
      if (playing) {
        await controller.stopAudio();
      } else if (recording || starting) {
        await controller.stopRecordingAndAsk();
      } else {
        HapticFeedback.lightImpact();
        await controller.startRecording();
      }
    }

    final enabled = controller.canUsePushToTalk || playing;
    return Row(children: [
      Expanded(
        child: Semantics(
          button: true,
          enabled: enabled,
          liveRegion: recording || processing,
          label: label,
          hint: playing
              ? 'Tap to stop playback'
              : recording
                  ? 'Tap to send your question'
                  : starting
                      ? 'Tap to cancel'
                      : 'Tap to start recording, or hold while speaking',
          onTap: enabled ? onTap : null,
          excludeSemantics: true,
          child: Listener(
            onPointerCancel: (_) => controller.cancelRecording(),
            child: GestureDetector(
              key: const ValueKey('push-to-talk'),
              behavior: HitTestBehavior.opaque,
              onLongPressStart: controller.canUsePushToTalk && !recording
                  ? (_) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      HapticFeedback.lightImpact();
                      controller.startRecording();
                    }
                  : null,
              onLongPressEnd: controller.canUsePushToTalk
                  ? (_) => controller.stopRecordingAndAsk()
                  : null,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: recording ? AppColors.orange : AppColors.ink,
                  backgroundColor:
                      recording ? AppColors.peach : Colors.transparent,
                  minimumSize: const Size(48, 48),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: enabled ? onTap : null,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (processing || starting)
                      const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      Icon(
                          playing
                              ? Icons.stop_circle_outlined
                              : recording
                                  ? Icons.graphic_eq_rounded
                                  : Icons.mic_none_rounded,
                          size: 22),
                    const SizedBox(width: 8),
                    Flexible(
                        child: Text(label,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600))),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      if (recording || starting)
        IconButton(
            tooltip: 'Cancel recording',
            onPressed: controller.cancelRecording,
            icon: const Icon(Icons.close_rounded, size: 20)),
    ]);
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          color: AppColors.muted));
}

class _InlineProgress extends StatelessWidget {
  const _InlineProgress(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Row(children: [
          const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(label,
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 12))),
        ]),
      );
}

class _WorkingAnswer extends StatelessWidget {
  const _WorkingAnswer({this.question});
  final String? question;
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (question != null) ...[
            const _Eyebrow('YOUR QUESTION'),
            const SizedBox(height: 8),
            Text(question!, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),
          ],
          const _InlineProgress('Finding the relevant moments…'),
        ],
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
            child: _InlineProgress('Getting your episodes ready…')),
      );
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary(
      {required this.onRefresh,
      required this.hasEpisodes,
      required this.onLibrary});
  final VoidCallback onRefresh;
  final bool hasEpisodes;
  final VoidCallback onLibrary;
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
                    : 'Episodes will appear here when they’re added to your library. Refresh to check for new arrivals.',
                style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: hasEpisodes ? onLibrary : onRefresh,
              icon: Icon(hasEpisodes
                  ? Icons.library_music_outlined
                  : Icons.refresh_rounded),
              label: Text(hasEpisodes ? 'Open library' : 'Refresh library'),
            ),
          ],
        ),
      );
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice(
      {required this.message, required this.onDismiss, this.onRetry});
  final String message;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;
  String get friendlyMessage {
    if (message.contains('permission') || message.contains('Permission')) {
      return 'Microphone access is off. Allow it in Settings, or type your question below.';
    }
    if (message.contains('empty text') || message.contains('No recorded')) {
      return 'I didn’t catch that. Try speaking again, or type your question.';
    }
    if (message.contains('voice playback')) {
      return 'Your answer is ready to read. Spoken playback is unavailable right now.';
    }
    if (message.contains('load episode')) {
      return 'We couldn’t load your episodes. Check your connection and try again.';
    }
    if (message.contains('play')) {
      return 'This audio couldn’t play. Check your connection and try again.';
    }
    return 'Something interrupted that request. Please try again. You can also type your question.';
  }

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
                      Text(friendlyMessage,
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

void _showDetails(BuildContext context, EpisodeDetail episode) {
  final description = episode.description
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  _showReadingSheet(
      context,
      episode.title,
      description.isEmpty
          ? 'No episode notes are available for this recording.'
          : description);
}

void _showExcerpt(BuildContext context, Citation citation) => _showReadingSheet(
    context,
    'From ${_timestamp(citation.startSec)} to ${_timestamp(citation.endSec)}',
    citation.text);

void _showReadingSheet(BuildContext context, String title, String body) {
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

String _timestamp(double seconds) {
  final total = seconds.round().clamp(0, 359999);
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

String _durationLabel(int seconds) =>
    seconds < 60 ? '$seconds sec' : '${(seconds / 60).ceil()} min';
