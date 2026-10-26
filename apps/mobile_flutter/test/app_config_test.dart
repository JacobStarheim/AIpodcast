import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_voice_ai/app_config.dart';

void main() {
  test('a defined API key is used as the service token', () {
    expect(resolveServiceApiKey('k1'), 'k1');
    expect(resolveServiceApiKey('  k1 \n'), 'k1');
  });

  test('without API_KEY there is no development key, even in debug builds', () {
    // Tests run as a debug build without --dart-define=API_KEY.
    expect(serviceApiKey, isEmpty);
    expect(resolveServiceApiKey(''), isEmpty);
  });
}
