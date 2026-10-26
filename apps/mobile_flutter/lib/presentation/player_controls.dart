import 'package:flutter/material.dart';

import '../podcast_controller.dart';
import 'formatting.dart';

/// Progress bar for the selected episode: elapsed and total time, and
/// seeking. It follows [PodcastController.selectedProgress] directly so
/// position updates do not rebuild the rest of the page.
class PlaybackProgressBar extends StatefulWidget {
  const PlaybackProgressBar({super.key, required this.controller});
  final PodcastController controller;

  @override
  State<PlaybackProgressBar> createState() => _PlaybackProgressBarState();
}

class _PlaybackProgressBarState extends State<PlaybackProgressBar> {
  /// The thumb position while dragging, so playback updates do not fight it.
  double? _dragValue;

  static const _active = Color(0xFFDCE9D5);
  static const _text = Color(0xFFB9C4BA);

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final hasAudio =
        controller.selectedEpisode?.episode.playbackUrl.isNotEmpty ?? false;
    return ValueListenableBuilder<PlaybackProgress>(
      valueListenable: controller.selectedProgress,
      builder: (context, progress, _) {
        final total = progress.duration;
        final max = total == null ? 0.0 : total.inMilliseconds.toDouble();
        final enabled = max > 0 && hasAudio && controller.canControlPlayback;
        final value = max > 0
            ? (_dragValue ?? progress.position.inMilliseconds.toDouble())
                .clamp(0.0, max)
            : 0.0;
        final shown = Duration(milliseconds: value.round());
        final totalLabel = total == null ? '--:--' : formatTimestamp(total);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: _active,
                inactiveTrackColor: const Color(0x33FFFFFF),
                thumbColor: Colors.white,
                overlayColor: const Color(0x22FFFFFF),
                disabledActiveTrackColor: const Color(0x66DCE9D5),
                disabledInactiveTrackColor: const Color(0x22FFFFFF),
                disabledThumbColor: const Color(0x99FFFFFF),
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 18),
              ),
              child: Semantics(
                label: 'Playback position',
                child: Slider(
                  key: const ValueKey('playback-slider'),
                  value: value,
                  max: max > 0 ? max : 1,
                  onChanged: enabled
                      ? (next) => setState(() => _dragValue = next)
                      : null,
                  onChangeEnd: enabled
                      ? (next) {
                          setState(() => _dragValue = null);
                          controller.seekSelectedEpisode(
                              Duration(milliseconds: next.round()));
                        }
                      : null,
                  semanticFormatterCallback: (next) =>
                      '${formatTimestamp(Duration(milliseconds: next.round()))} of $totalLabel',
                ),
              ),
            ),
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(children: [
                  Text(formatTimestamp(shown),
                      key: const ValueKey('playback-elapsed'),
                      style: const TextStyle(color: _text, fontSize: 12)),
                  const Spacer(),
                  Text(totalLabel,
                      key: const ValueKey('playback-total'),
                      style: const TextStyle(color: _text, fontSize: 12)),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}
