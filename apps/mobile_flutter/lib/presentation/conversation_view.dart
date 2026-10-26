import 'package:flutter/material.dart';

import '../models.dart';
import '../podcast_controller.dart';
import 'app_theme.dart';
import 'common.dart';
import 'formatting.dart';

/// Scope toggle, the question/answer turns of the current conversation
/// (newest at the bottom) and the state of the question being answered.
class ConversationSection extends StatelessWidget {
  const ConversationSection({
    super.key,
    required this.controller,
    required this.onAsk,
    required this.newestTurnKey,
  });
  final PodcastController controller;
  final ValueChanged<String> onAsk;
  final GlobalKey newestTurnKey;

  @override
  Widget build(BuildContext context) {
    final turns = controller.conversation;
    final pending = controller.pendingQuestion;
    final working = controller.voiceState == VoiceState.processing &&
        !controller.isPreparingSpeech &&
        (controller.isTranscribingVoice || pending != null);
    final error = controller.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ScopeBar(controller: controller),
        const SizedBox(height: 20),
        if (turns.isEmpty && pending == null && !working)
          _QuestionIdeas(
            library: controller.scope == QuestionScope.library,
            ready: controller.isScopeReady,
            enabled: controller.canAskQuestion,
            onAsk: onAsk,
          ),
        for (var index = 0; index < turns.length; index++) ...[
          if (index > 0) const SizedBox(height: 28),
          _TurnView(
            key: index == turns.length - 1 ? newestTurnKey : null,
            turn: turns[index],
            controller: controller,
            newest: index == turns.length - 1,
          ),
        ],
        if (working) ...[
          if (turns.isNotEmpty) const SizedBox(height: 28),
          _WorkingAnswer(question: pending, controller: controller),
        ] else if (pending != null) ...[
          if (turns.isNotEmpty) const SizedBox(height: 28),
          _QuestionHeader(question: pending),
        ],
        if (error != null && error.belongsToConversation) ...[
          const SizedBox(height: 16),
          ErrorNotice(message: error.message, onDismiss: controller.dismissError),
        ],
      ],
    );
  }
}

class _ScopeBar extends StatelessWidget {
  const _ScopeBar({required this.controller});
  final PodcastController controller;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.canChangeConversation;
    final hasConversation = controller.conversation.isNotEmpty ||
        controller.pendingQuestion != null;
    Widget choice(String label, QuestionScope scope, IconData icon) =>
        ChoiceChip(
          key: ValueKey('scope-${scope.name}'),
          label: Text(label),
          avatar: Icon(icon, size: 16),
          showCheckmark: false,
          selected: controller.scope == scope,
          selectedColor: AppColors.sage,
          backgroundColor: Colors.white,
          side: const BorderSide(color: AppColors.line),
          onSelected: enabled ? (_) => controller.setScope(scope) : null,
        );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        choice('This episode', QuestionScope.episode, Icons.podcasts_rounded),
        choice('Whole library', QuestionScope.library,
            Icons.library_books_outlined),
        if (hasConversation)
          TextButton.icon(
            key: const ValueKey('new-conversation'),
            style: TextButton.styleFrom(
                foregroundColor: AppColors.green,
                minimumSize: const Size(48, 48)),
            onPressed: enabled ? controller.startNewConversation : null,
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            label: const Text('New conversation'),
          ),
      ],
    );
  }
}

class _QuestionIdeas extends StatelessWidget {
  const _QuestionIdeas({
    required this.library,
    required this.ready,
    required this.enabled,
    required this.onAsk,
  });
  final bool library;
  final bool ready;
  final bool enabled;
  final ValueChanged<String> onAsk;

  @override
  Widget build(BuildContext context) {
    final ideas = library
        ? const [
            ('Common themes', Icons.hub_outlined,
                'What themes come up across these episodes?'),
            ('Where to start', Icons.explore_outlined,
                'Which episode should I listen to first, and why?'),
          ]
        : const [
            ('The big picture', Icons.auto_awesome_outlined,
                'What is this episode about?'),
            ('Key takeaways', Icons.lightbulb_outline_rounded,
                'What are the key takeaways from this episode?'),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
            ready
                ? 'Follow your curiosity.'
                : library
                    ? 'Nothing to search yet.'
                    : 'A little more listening, first.',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
            ready
                ? library
                    ? 'Ask across every transcribed episode. Answers link back to what was said.'
                    : 'Ask about this episode. Every answer links back to what was said.'
                : library
                    ? 'Questions will be available once an episode in your library is transcribed.'
                    : 'Questions will be available once the transcript is ready.',
            style: const TextStyle(
                color: AppColors.muted, fontSize: 14, height: 1.5)),
        if (ready) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (label, icon, question) in ideas)
              _Suggestion(
                  label: label,
                  icon: icon,
                  onTap: enabled ? () => onAsk(question) : null),
          ]),
        ],
      ],
    );
  }
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

class _QuestionHeader extends StatelessWidget {
  const _QuestionHeader({required this.question, this.positionSec});
  final String question;
  final double? positionSec;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Eyebrow(positionSec == null
              ? 'YOUR QUESTION'
              : 'YOUR QUESTION · AT ${timestampFromSeconds(positionSec!)}'),
          const SizedBox(height: 8),
          Text(question, style: Theme.of(context).textTheme.titleMedium),
        ],
      );
}

/// The question being answered: what the server is doing, and the answer
/// text as it streams in. The final answer replaces it.
class _WorkingAnswer extends StatelessWidget {
  const _WorkingAnswer({this.question, required this.controller});
  final String? question;
  final PodcastController controller;

  @override
  Widget build(BuildContext context) {
    final library = controller.scope == QuestionScope.library;
    final label = question == null
        ? 'Listening back to your question…'
        : switch (controller.answerStage) {
            AnswerStage.answering => 'Answering…',
            _ => library ? 'Searching your library…' : 'Searching the episode…',
          };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (question != null) ...[
          _QuestionHeader(question: question!),
          const SizedBox(height: 20),
        ],
        ValueListenableBuilder<String>(
          valueListenable: controller.streamingAnswer,
          builder: (context, text, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (question != null && text.isNotEmpty) ...[
                Container(
                  key: const ValueKey('streaming-answer'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: AppColors.line),
                      borderRadius: BorderRadius.circular(22)),
                  child: Text(text,
                      style: const TextStyle(
                          fontSize: 16, height: 1.6, color: AppColors.ink)),
                ),
                const SizedBox(height: 14),
              ],
              InlineProgress(label, key: const ValueKey('answer-stage')),
            ],
          ),
        ),
      ],
    );
  }
}

class _TurnView extends StatelessWidget {
  const _TurnView({
    super.key,
    required this.turn,
    required this.controller,
    required this.newest,
  });
  final ConversationTurn turn;
  final PodcastController controller;
  final bool newest;

  @override
  Widget build(BuildContext context) {
    final response = turn.response;
    final library = controller.scope == QuestionScope.library;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _QuestionHeader(question: turn.question, positionSec: turn.positionSec),
        const SizedBox(height: 16),
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
                            ? library
                                ? 'From your library'
                                : 'From this episode'
                            : library
                                ? 'Not covered in your library'
                                : 'Not covered in this episode',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14))),
              ]),
              const SizedBox(height: 14),
              SelectableText(
                  // Refusals come in the language of the question.
                  response.grounded || response.answerText.trim().isNotEmpty
                      ? response.answerText
                      : library
                          ? 'I couldn’t find enough detail in your transcribed episodes to answer that. Try asking about a topic they discuss.'
                          : 'I couldn’t find enough detail in the transcript to answer that. Try asking about a topic discussed in this episode.',
                  style: const TextStyle(
                      fontSize: 16, height: 1.6, color: AppColors.ink)),
              if (newest && controller.isPreparingSpeech) ...[
                const SizedBox(height: 14),
                const InlineProgress('Preparing spoken answer…'),
              ],
              if (response.citations.isNotEmpty) ...[
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Divider(height: 1)),
                const Eyebrow('HEAR IT IN CONTEXT'),
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
    final active = controller.activeCitationId == citation.segmentId &&
        controller.isAudioPlaying;
    final enabled = controller.canControlPlayback;
    final otherEpisode =
        citation.episodeId != controller.selectedEpisode?.episode.id &&
            citation.episodeTitle.isNotEmpty;
    void onTap() => active
        ? controller.pausePlayback()
        : controller.playCitation(citation);
    return Material(
      color: active ? AppColors.peach : AppColors.sage,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (citation.kind == CitationKind.chapter) ...[
                const Eyebrow('CHAPTER', color: AppColors.green),
                const SizedBox(height: 6),
              ],
              if (otherEpisode) ...[
                Text(citation.episodeTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.green)),
                const SizedBox(height: 6),
              ],
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
                    onPressed: enabled ? onTap : null,
                    icon: Icon(
                        active
                            ? Icons.pause_circle_outline_rounded
                            : Icons.play_circle_outline_rounded,
                        size: 25),
                    label: Text(
                        active
                            ? 'Pause'
                            : 'Listen from ${timestampFromSeconds(citation.playFromSec)}',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
                IconButton(
                  tooltip: 'Read full excerpt',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  padding: EdgeInsets.zero,
                  onPressed: () => showReadingSheet(
                      context,
                      'From ${timestampFromSeconds(citation.startSec)} to ${timestampFromSeconds(citation.endSec)}',
                      citation.text),
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
