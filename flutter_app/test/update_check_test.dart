import 'package:flutter_test/flutter_test.dart';

import 'package:serene_app/src/update_check.dart';

/// Surum karsilastirmasi ve govde cozumlemesi saf fonksiyonlardir: ag yok,
/// motor yok. Guncelleme uyarisinin yanlis cikmamasi (muhafazakar davranis)
/// burada olculur.
void main() {
  group('isNewerVersion', () {
    test('sayisal parcalari karsilastirir', () {
      expect(isNewerVersion('1.0.1', '1.0.0'), isTrue);
      expect(isNewerVersion('1.1.0', '1.0.9'), isTrue);
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
      expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
      expect(isNewerVersion('0.9.9', '1.0.0'), isFalse);
    });

    test('basindaki v ve +build ekini yok sayar', () {
      expect(isNewerVersion('v1.2.0', '1.1.9'), isTrue);
      expect(isNewerVersion('1.2.0+build', '1.1.0'), isTrue);
      expect(isNewerVersion('1.0.0', 'v1.0.0'), isFalse);
    });

    test('kisa surumleri sifirla tamamlar', () {
      expect(isNewerVersion('1.1', '1.0.0'), isTrue);
      expect(isNewerVersion('1', '0.9.9'), isTrue);
    });

    test('cozulemeyen surumde guncelleme gostermez', () {
      expect(isNewerVersion('abc', '1.0.0'), isFalse);
      expect(isNewerVersion('1.0.0', ''), isFalse);
      expect(isNewerVersion('', '1.0.0'), isFalse);
    });
  });

  group('parseUpdate', () {
    test('GitHub surum JSONu', () {
      final info = parseUpdate(
        '{"tag_name":"v1.1.0",'
        '"html_url":"https://github.com/x/y/releases/tag/v1.1.0"}',
      );
      expect(info?.version, 'v1.1.0');
      expect(info?.url, 'https://github.com/x/y/releases/tag/v1.1.0');
    });

    test('sade latest.json', () {
      final info = parseUpdate(
        '{"version":"1.1.0","url":"https://example.com/dl"}',
      );
      expect(info?.version, '1.1.0');
      expect(info?.url, 'https://example.com/dl');
    });

    test('eksik ya da gecersiz govdede null', () {
      expect(parseUpdate('{"tag_name":"1.1.0"}'), isNull);
      expect(parseUpdate('{"version":"1.1.0"}'), isNull);
      expect(parseUpdate('{"url":"https://x"}'), isNull);
      expect(parseUpdate('[]'), isNull);
      expect(parseUpdate('duz metin'), isNull);
    });
  });
}
