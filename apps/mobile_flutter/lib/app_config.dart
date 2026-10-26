import 'package:flutter/foundation.dart';

const String configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');
const String _configuredApiKey = String.fromEnvironment('API_KEY');

String get apiBaseUrl => configuredApiBaseUrl.isNotEmpty
    ? configuredApiBaseUrl
    : defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:4000'
        : 'http://localhost:4000';

/// A service token from `--dart-define=API_KEY=...` (the server's
/// `APP_API_KEY`). With it the app skips signing in; without it, every build
/// (debug included) shows the sign-in screen.
String get serviceApiKey => resolveServiceApiKey(_configuredApiKey);

String resolveServiceApiKey(String configured) => configured.trim();
