import 'dart:async';

import 'package:flutter/material.dart';

import 'app_config.dart';
import 'audio_output.dart';
import 'conversation_store.dart';
import 'media_session.dart';
import 'playback_position_store.dart';
import 'podcast_api.dart';
import 'podcast_controller.dart';
import 'presentation/app_theme.dart';
import 'presentation/home_page.dart';
import 'presentation/login_page.dart';
import 'session_controller.dart';
import 'session_store.dart';
import 'voice_recorder.dart';

export 'presentation/home_page.dart' show PodcastHomePage;
export 'presentation/login_page.dart' show LoginPage;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // One media session for the app's lifetime: lock screen, notification and
  // background playback of episodes.
  final mediaSession = await startMediaSession();
  late final SessionController session;
  final api = HttpPodcastApi(
    baseUrl: apiBaseUrl,
    authToken: () => session.token,
    onUnauthorized: (token) => session.handleUnauthorized(token),
  );
  session = SessionController(
    api: api,
    store: SecureSessionStore(),
    serviceToken: serviceApiKey,
  );
  unawaited(session.restore());
  runApp(PodcastVoiceApp(
    session: session,
    createController: (session) => PodcastController(
      api: api,
      recorder: RecordVoiceRecorder(onStopped: configureAudioSession),
      audioOutput: JustAudioOutput(mediaSession: mediaSession),
      positionStore: SharedPreferencesPositionStore(),
      conversationStore:
          SharedPreferencesConversationStore(namespace: session.accountKey),
    ),
  ));
}

/// The app. With a [session] it shows the sign-in screen until someone is
/// signed in and builds a fresh controller for each session with
/// [createController]; without one it shows [controller] directly.
class PodcastVoiceApp extends StatelessWidget {
  const PodcastVoiceApp({
    super.key,
    this.controller,
    this.session,
    this.createController,
  }) : assert(controller != null || createController != null);

  final PodcastController? controller;
  final SessionController? session;
  final PodcastController Function(SessionController session)? createController;

  @override
  Widget build(BuildContext context) {
    final session = this.session;
    return MaterialApp(
      title: 'Podcast',
      debugShowCheckedModeBanner: false,
      theme: podcastTheme(),
      home: session == null
          ? PodcastHomePage(controller: controller)
          : _SessionGate(
              session: session,
              createController: createController ?? (_) => controller!,
            ),
    );
  }
}

class _SessionGate extends StatefulWidget {
  const _SessionGate({required this.session, required this.createController});
  final SessionController session;
  final PodcastController Function(SessionController session) createController;

  @override
  State<_SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<_SessionGate> {
  late int? _signedInSession = _currentSession;

  int? get _currentSession =>
      widget.session.isSignedIn ? widget.session.sessionId : null;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    final current = _currentSession;
    final ended = _signedInSession != null && current != _signedInSession;
    _signedInSession = current;
    // Sheets and dialogs of the session that ended (e.g. after a 401) must
    // not stay open above the sign-in screen.
    if (ended && mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => switch (session.status) {
        SessionStatus.restoring => const _Restoring(),
        SessionStatus.signedOut => LoginPage(session: session),
        // A new key per session: signing out disposes the controller
        // (stopping playback) and the next account starts fresh.
        SessionStatus.signedIn => PodcastHomePage(
            key: ValueKey('session-${session.sessionId}'),
            session: session,
            createController: () => widget.createController(session),
          ),
      },
    );
  }
}

class _Restoring extends StatelessWidget {
  const _Restoring();

  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: AppColors.paper,
        body: Center(
          child: SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(
                strokeWidth: 2, semanticsLabel: 'Opening the app'),
          ),
        ),
      );
}
