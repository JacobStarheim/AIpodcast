import 'package:flutter/material.dart';

import '../models.dart';
import '../podcast_controller.dart';
import 'app_theme.dart';
import 'episode_art.dart';
import 'formatting.dart';
import 'player_controls.dart';

/// The selected episode with its player and transcript state.
class EpisodeCard extends StatelessWidget {
  const EpisodeCard(
      {super.key, required this.controller, required this.onDetails});
  final PodcastController controller;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final envelope = controller.selectedEpisode!;
    final episode = envelope.episode;
    final status = envelope.transcriptionStatus;
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(episode.publishedAt.toLocal());
    final duration = episode.durationSec;
    final otherEpisode = controller.nowPlaying;
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
                child: Text(statusLabel(status),
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
                PodcastArtwork(
                    imageUrl: episode.imageUrl,
                    seed: episode.sourceName,
                    size: 86),
                const SizedBox(width: 16),
                Expanded(child: title),
              ],
            );
          }),
          const SizedBox(height: 18),
          Text(
              '$date${duration != null ? '  ·  ${durationLabel(duration)}' : ''}',
              style: const TextStyle(color: Color(0xFFB9C4BA), fontSize: 12)),
          if (status != TranscriptionStatus.ready) ...[
            const SizedBox(height: 12),
            _TranscriptNote(controller: controller, episode: episode),
          ],
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: _PlayButton(controller: controller)),
            const SizedBox(width: 10),
            IconButton(
              tooltip: 'Episode details',
              style: IconButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF536056))),
              onPressed: onDetails,
              icon: const Icon(Icons.notes_rounded, size: 21),
            ),
          ]),
          const SizedBox(height: 6),
          PlaybackProgressBar(controller: controller),
          if (otherEpisode != null && otherEpisode.id != episode.id)
            _OtherEpisodePlaying(controller: controller, episode: otherEpisode),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.controller});
  final PodcastController controller;

  @override
  Widget build(BuildContext context) {
    final episode = controller.selectedEpisode!.episode;
    final playing = controller.isPlayingEpisode;
    final resumable =
        controller.selectedProgress.value.position >= const Duration(seconds: 1);
    return FilledButton.icon(
      key: const ValueKey('play-episode'),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFDCE9D5),
        foregroundColor: AppColors.ink,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      ),
      onPressed: controller.canControlPlayback && episode.audioUrl.isNotEmpty
          ? controller.togglePlayback
          : null,
      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 24),
      label: Text(playing
          ? 'Pause'
          : resumable
              ? 'Resume'
              : 'Play episode'),
    );
  }
}

class _TranscriptNote extends StatelessWidget {
  const _TranscriptNote({required this.controller, required this.episode});
  final PodcastController controller;
  final EpisodeDetail episode;

  @override
  Widget build(BuildContext context) {
    final status = controller.selectedEpisode!.transcriptionStatus;
    final requesting = controller.isTranscriptionRequested(episode.id);
    final reason = episode.transcriptionError;
    final message = switch (status) {
      TranscriptionStatus.pending =>
        'Transcribe this episode to ask questions about it. You can listen meanwhile.',
      TranscriptionStatus.queued =>
        'Transcription is queued. It usually takes a few minutes, and you can listen meanwhile.',
      TranscriptionStatus.processing =>
        'Transcribing now. Questions open up as soon as it’s done.',
      TranscriptionStatus.failed => reason == null
          ? 'Transcription failed. You can try again, or just listen.'
          : 'Transcription failed: $reason',
      TranscriptionStatus.ready => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message,
            style: const TextStyle(color: Color(0xFFD9DED5), fontSize: 13)),
        if (status.canRequestTranscription) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const ValueKey('transcribe-selected'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size(48, 48),
              side: const BorderSide(color: Color(0xFF7E8C81)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: requesting
                ? null
                : () => controller.requestTranscription(episode.id),
            icon: requesting
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Colors.white))
                : const Icon(Icons.subtitles_outlined, size: 18),
            label: Text(requesting
                ? 'Requesting…'
                : status == TranscriptionStatus.failed
                    ? 'Try transcribing again'
                    : 'Transcribe episode'),
          ),
        ] else if (status.isInProgress) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(
              minHeight: 2,
              color: Color(0xFFDCE9D5),
              backgroundColor: Color(0x22FFFFFF)),
        ],
      ],
    );
  }
}

/// Shown while a citation from another episode is in the player.
class _OtherEpisodePlaying extends StatelessWidget {
  const _OtherEpisodePlaying({required this.controller, required this.episode});
  final PodcastController controller;
  final EpisodeDetail episode;

  @override
  Widget build(BuildContext context) {
    final playing = controller.isAudioPlaying;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
          color: const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        const Icon(Icons.headphones_rounded, size: 16, color: Colors.white),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              '${playing ? 'Playing' : 'Paused'}: ${episode.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
        IconButton(
          tooltip: playing ? 'Pause cited episode' : 'Resume cited episode',
          style: IconButton.styleFrom(foregroundColor: Colors.white),
          onPressed:
              controller.canControlPlayback ? controller.toggleNowPlaying : null,
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
      ]),
    );
  }
}
