import 'package:flutter/material.dart';

import 'audio_output.dart';
import 'models.dart';
import 'podcast_api.dart';
import 'podcast_controller.dart';
import 'voice_recorder.dart';

const String apiBaseUrl =
    String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:4000');

void main() {
  runApp(const PodcastVoiceApp());
}

class PodcastVoiceApp extends StatelessWidget {
  const PodcastVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Podcast Voice Q&A',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const PodcastHomePage(),
    );
  }
}

class PodcastHomePage extends StatefulWidget {
  const PodcastHomePage({super.key});

  @override
  State<PodcastHomePage> createState() => _PodcastHomePageState();
}

class _PodcastHomePageState extends State<PodcastHomePage> {
  late final PodcastController controller;
  final TextEditingController questionController = TextEditingController();

  @override
  void initState() {
    super.initState();

    controller = PodcastController(
      api: HttpPodcastApi(baseUrl: apiBaseUrl),
      recorder: RecordVoiceRecorder(),
      audioOutput: JustAudioOutput(),
    )..addListener(_onControllerUpdated);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.loadInitialEpisodes();
    });
  }

  void _onControllerUpdated() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerUpdated);
    controller.close();
    controller.dispose();
    questionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedEpisode = controller.selectedEpisode?.episode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Podcast Voice Q&A'),
        actions: [
          IconButton(
            onPressed: controller.loadInitialEpisodes,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: controller.isLoadingEpisodes
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (controller.errorMessage != null)
                      _ErrorBanner(message: controller.errorMessage!),
                    const Text(
                      'Episodes',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      flex: 2,
                      child: _EpisodeList(controller: controller),
                    ),
                    const SizedBox(height: 10),
                    if (selectedEpisode != null)
                      _EpisodeHeader(
                        title: selectedEpisode.title,
                        sourceName: selectedEpisode.sourceName,
                        status: controller.selectedEpisode!.transcriptionStatus,
                      ),
                    const SizedBox(height: 8),
                    _QuestionInput(
                      controller: questionController,
                      onSubmit: () async {
                        final text = questionController.text;
                        questionController.clear();
                        await controller.submitTypedQuestion(text);
                      },
                    ),
                    const SizedBox(height: 8),
                    _PushToTalkButton(controller: controller),
                    const SizedBox(height: 10),
                    Expanded(
                      flex: 2,
                      child: _AnswerPanel(controller: controller),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _EpisodeList extends StatelessWidget {
  const _EpisodeList({required this.controller});

  final PodcastController controller;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: controller.episodes.length + (controller.hasMoreEpisodes ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= controller.episodes.length) {
          return ListTile(
            title: const Text('Load more episodes'),
            trailing: controller.isLoadingMore
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.expand_more),
            onTap: controller.isLoadingMore ? null : controller.loadMoreEpisodes,
          );
        }

        final episode = controller.episodes[index];
        final selectedId = controller.selectedEpisode?.episode.id;

        return ListTile(
          selected: selectedId == episode.id,
          title: Text(episode.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${episode.sourceName} • ${episode.publishedAt.toLocal().toIso8601String().split('T').first}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _StatusChip(status: episode.transcriptionStatus),
          onTap: () => controller.selectEpisode(episode.id),
        );
      },
    );
  }
}

class _EpisodeHeader extends StatelessWidget {
  const _EpisodeHeader({
    required this.title,
    required this.sourceName,
    required this.status,
  });

  final String title;
  final String sourceName;
  final TranscriptionStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(sourceName),
                ],
              ),
            ),
            _StatusChip(status: status),
          ],
        ),
      ),
    );
  }
}

class _QuestionInput extends StatelessWidget {
  const _QuestionInput({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Type a question (optional)',
            ),
            minLines: 1,
            maxLines: 2,
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: onSubmit,
          child: const Text('Ask'),
        ),
      ],
    );
  }
}

class _PushToTalkButton extends StatelessWidget {
  const _PushToTalkButton({required this.controller});

  final PodcastController controller;

  String _labelForState(VoiceState state) {
    switch (state) {
      case VoiceState.recording:
        return 'Recording... release to ask';
      case VoiceState.processing:
        return 'Processing...';
      case VoiceState.speaking:
        return 'Speaking...';
      case VoiceState.idle:
        return 'Hold to talk';
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = !controller.isEpisodeReady ||
        controller.voiceState == VoiceState.processing ||
        controller.voiceState == VoiceState.speaking;

    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: GestureDetector(
        onLongPressStart: disabled ? null : (_) => controller.startRecording(),
        onLongPressEnd: disabled ? null : (_) => controller.stopRecordingAndAsk(),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: null,
            icon: const Icon(Icons.mic),
            label: Text(_labelForState(controller.voiceState)),
          ),
        ),
      ),
    );
  }
}

class _AnswerPanel extends StatelessWidget {
  const _AnswerPanel({required this.controller});

  final PodcastController controller;

  @override
  Widget build(BuildContext context) {
    final response = controller.latestResponse;

    if (response == null) {
      return const Card(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('Ask a question to see transcript-grounded answers and citations.'),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  response.grounded ? 'Grounded Answer' : 'Refusal',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                if (!response.grounded)
                  Text(
                    response.refusalReason ?? 'insufficient evidence',
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(response.answerText),
            const SizedBox(height: 10),
            const Text(
              'Citations',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: response.citations.isEmpty
                  ? const Text('No citations for this response.')
                  : ListView.builder(
                      itemCount: response.citations.length,
                      itemBuilder: (context, index) {
                        final citation = response.citations[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            citation.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_formatTimestamp(citation.startSec)} - ${_formatTimestamp(citation.endSec)}',
                          ),
                          trailing: const Icon(Icons.play_arrow),
                          onTap: () => controller.playCitation(citation),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final TranscriptionStatus status;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case TranscriptionStatus.ready:
        return const Chip(label: Text('Ready'));
      case TranscriptionStatus.failed:
        return const Chip(label: Text('Failed'));
      case TranscriptionStatus.pending:
        return const Chip(label: Text('Transcribing'));
    }
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.red.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(message, style: const TextStyle(color: Colors.black87)),
    );
  }
}

String _formatTimestamp(double seconds) {
  final total = seconds.round();
  final minutes = total ~/ 60;
  final remainingSeconds = total % 60;
  return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
}
