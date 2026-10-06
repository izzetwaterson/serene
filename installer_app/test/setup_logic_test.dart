// `setup_logic.dart`in Windows'a dokunmayan saf yuzeyi.
//
// Kur/kaldir AKISI (registry yazimi, dosya kopyalama/silme sirasi) dogrudan
// isletim sistemine bagli oldugu icin burada test edilmez; onun icin yan
// etkilerin soyutlanmasi gerekir. Burada kaydirma/arguman gibi saf kararlar
// sınanir.

import 'package:flutter_test/flutter_test.dart';
import 'package:serene_setup/setup_logic.dart';

void main() {
  group('normalizeInstallDir', () {
    test('son parca zaten Serene ise dokunmaz', () {
      expect(normalizeInstallDir(r'C:\Program Files\Serene'), r'C:\Program Files\Serene');
      expect(normalizeInstallDir(r'D:\Serene'), r'D:\Serene');
    });

    test('son parca Serene degilse altina ekler', () {
      expect(normalizeInstallDir(r'D:\Oyunlar'), r'D:\Oyunlar\Serene');
      expect(normalizeInstallDir(r'C:\Program Files'), r'C:\Program Files\Serene');
    });

    test('sondaki ters boluyu temizler', () {
      expect(normalizeInstallDir(r'D:\Oyunlar\'), r'D:\Oyunlar\Serene');
      expect(normalizeInstallDir(r'D:\Oyunlar\\'), r'D:\Oyunlar\Serene');
    });

    test('ileri boluyu ters boluye cevirir', () {
      expect(normalizeInstallDir('C:/Users/x/serene'), r'C:\Users\x\serene');
      expect(normalizeInstallDir('C:/Users/x/Alt'), r'C:\Users\x\Alt\Serene');
    });

    test('bastaki/sondaki bosluklari kirpar', () {
      expect(normalizeInstallDir('  D:\\a  '), r'D:\a\Serene');
    });

    test('buyuk/kucuk harf farketmez', () {
      expect(normalizeInstallDir(r'D:\SERENE'), r'D:\SERENE');
    });
  });

  group('SetupArgs.parse', () {
    test('bos argumanlar guvenli varsayilanlari verir', () {
      final args = SetupArgs.parse(const []);
      expect(args.uninstall, isFalse);
      expect(args.silent, isFalse);
      expect(args.startMenu, isTrue);
      expect(args.autostart, isFalse);
      expect(args.keepData, isTrue); // veri varsayilan korunur
      expect(args.dir, isNull);
      expect(args.lang, isNull);
      expect(args.preview, isNull);
    });

    test('uninstall + kaldirma bayraklarini okur', () {
      final args = SetupArgs.parse(const ['--uninstall', '--silent', '--delete-data']);
      expect(args.uninstall, isTrue);
      expect(args.silent, isTrue);
      expect(args.keepData, isFalse);
    });

    test('deger alan bayraklari okur', () {
      final args = SetupArgs.parse(const [
        '--dir',
        r'D:\Serene',
        '--version',
        '2.0.0',
        '--payload',
        r'C:\tmp\payload',
        '--lang',
        'tr',
        '--page',
        'options',
      ]);
      expect(args.dir, r'D:\Serene');
      expect(args.version, '2.0.0');
      expect(args.payload, r'C:\tmp\payload');
      expect(args.lang, 'tr');
      expect(args.preview, 'options');
    });

    test('--no-startmenu ve --autostart ayarlari cevirir', () {
      final args = SetupArgs.parse(const ['--no-startmenu', '--autostart']);
      expect(args.startMenu, isFalse);
      expect(args.autostart, isTrue);
    });

    test('deger bekleyen bayrak sonda kalirsa cokmez', () {
      final args = SetupArgs.parse(const ['--dir']);
      expect(args.dir, isNull);
    });
  });
}
