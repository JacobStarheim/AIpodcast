import 'package:flutter/foundation.dart';

const String configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');
const String _configuredApiKey = String.fromEnvironment('API_KEY');
const bool _hasConfiguredApiKey = bool.hasEnvironment('API_KEY');

/// Key that matches the API's example environment (`apps/api/.env.example`).
const String developmentApiKey = 'dev-app-key';

String get apiBaseUrl => configuredApiBaseUrl.isNotEmpty
    ? configuredApiBaseUrl
    : defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:4000'
        : 'http://localhost:4000';

/// The app key from `--dart-define=API_KEY=...`. Without it, debug builds use
/// [developmentApiKey] and other builds send no key.
String get apiKey => resolveApiKey(
      isDefined: _hasConfiguredApiKey,
      configured: _configuredApiKey,
      debug: kDebugMode,
    );

String resolveApiKey({
  required bool isDefined,
  required String configured,
  required bool debug,
}) {
  if (isDefined) return configured;
  return debug ? developmentApiKey : '';
}
