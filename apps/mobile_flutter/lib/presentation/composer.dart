import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../podcast_controller.dart';
import 'app_theme.dart';
import 'formatting.dart';

/// The question input, pinned above the keyboard.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.textController,
    required this.focusNode,
    required this.onSubmit,
  });
  final PodcastController controller;
  final TextEditingController textController;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final library = controller.scope == QuestionScope.library;
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
                    _PositionChip(controller: controller),
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
                          hintText: library
                              ? 'Ask across your library…'
                              : 'Ask about this episode…',
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

/// "About 12:34": the moment in the episode the next question refers to.
/// Dismiss it to ask without the playback position.
class _PositionChip extends StatelessWidget {
  const _PositionChip({required this.controller});
  final PodcastController controller;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<PlaybackProgress>(
        valueListenable: controller.selectedProgress,
        builder: (context, _, __) {
          final position = controller.questionPosition;
          if (position == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Chip(
                key: const ValueKey('question-position'),
                avatar: const Icon(Icons.graphic_eq_rounded,
                    size: 16, color: AppColors.green),
                label: Text('About ${formatTimestamp(position)}'),
                labelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.green),
                backgroundColor: AppColors.sage,
                side: BorderSide.none,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                deleteIconColor: AppColors.green,
                deleteButtonTooltipMessage: 'Ask without the playback position',
                onDeleted: controller.voiceState == VoiceState.idle
                    ? controller.dismissQuestionPosition
                    : null,
              ),
            ),
          );
        },
      );
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
    final speaking = state == VoiceState.speaking;
    final label = switch (state) {
      VoiceState.starting => 'Opening microphone…',
      VoiceState.recording => 'Listening · tap to send',
      VoiceState.processing => controller.isPreparingSpeech
          ? 'Preparing audio…'
          : 'Finding an answer…',
      VoiceState.speaking => 'Stop spoken answer',
      VoiceState.idle => 'Tap or hold to ask',
    };
    Future<void> onTap() async {
      FocusManager.instance.primaryFocus?.unfocus();
      if (speaking) {
        await controller.stopSpeech();
      } else if (recording || starting) {
        await controller.stopRecordingAndAsk();
      } else {
        HapticFeedback.lightImpact();
        await controller.startRecording();
      }
    }

    final enabled = controller.canUsePushToTalk || speaking;
    return Row(children: [
      Expanded(
        child: Semantics(
          button: true,
          enabled: enabled,
          liveRegion: recording || processing,
          label: label,
          hint: speaking
              ? 'Tap to skip the spoken answer'
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
                          speaking
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
