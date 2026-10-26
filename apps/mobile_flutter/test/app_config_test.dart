import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_voice_ai/app_config.dart';

void main() {
  test('a defined API key is always used, even when empty', () {
    expect(resolveApiKey(isDefined: true, configured: 'k1', debug: true), 'k1');
    expect(resolveApiKey(isDefined: true, configured: 'k1', debug: false), 'k1');
    expect(resolveApiKey(isDefined: true, configured: '', debug: true), '');
  });

  test('without a defined key, only debug builds use the development key',
      () {
    expect(resolveApiKey(isDefined: false, configured: '', debug: true),
        'dev-app-key');
    expect(resolveApiKey(isDefined: false, configured: '', debug: false), '');
  });
}
