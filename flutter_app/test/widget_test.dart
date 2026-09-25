import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:serene_app/src/app_theme.dart';
import 'package:serene_app/src/data.dart';
import 'package:serene_app/src/format.dart';
import 'package:serene_app/src/handoff.dart';
import 'package:serene_app/src/rust/api/dto.dart' as engine;
import 'package:serene_app/src/settings_view.dart';
import 'package:serene_app/src/theme.dart';

Settings _engineSettings() => Settings(
      downloadDir: r'C:\indir',
      maxConcurrent: 3,
      connections: 8,
      watchClipboard: false,
      closeToTray: true,
      confirmBrowserDownload: true,
      theme: 'system',
    );

void main() {
  // Palet globaldir; bir testin biraktigi mod digerine sizmasin.
  tearDown(() => applyThemeMode(ThemeMode.system));

  test('bayt bicimlendirme', () {
    expect(fmtBytes(0), '0 B');
    expect(fmtBytes(512), '512 B');
    expect(fmtBytes(1024), '1.0 KB');
    expect(fmtBytes(1048576), '1.0 MB');
  });

  test('gorev json okuma', () {
    final task = Task.fromJson({
      'id': 'a',
      'url': 'https://ornek/x.mp4',
      'filename': 'x.mp4',
      'dest': r'C:\indir\x.mp4',
      'total': 2048,
      'downloaded': 1024,
      'speed': 0,
      'status': 'paused',
      'category': 'video',
      'created_at': 0,
    });
    expect(task.filename, 'x.mp4');
    expect(task.dir, r'C:\indir');
    expect(percentOf(task), 50);
  });

  test('motor kaydindan arayuz gorevi', () {
    final task = Task.fromEngine(engine.Task(
      id: 'a',
      url: 'https://ornek/x.mp4',
      filename: 'x.mp4',
      dest: r'C:\indir\x.mp4',
      tempDir: r'C:\indir\x.mp4.parts',
      total: 2048,
      downloaded: 1024,
      speed: 0,
      status: engine.TaskStatus.paused,
      category: engine.FileCategory.video,
      resumable: true,
      segments: const [],
      createdAt: 0,
      kind: engine.MediaKind.file,
      pending: false,
    ));
    expect(task.status, 'paused');
    expect(task.category, 'video');
    expect(task.kind, 'file');
    expect(task.dir, r'C:\indir');
    expect(percentOf(task), 50);
  });

  test('yakalama turu etiketi', () {
    final item = CaptureItem.fromEngine(engine.Capture(
      id: 'c',
      url: 'https://ornek/master.m3u8',
      filename: '',
      size: 4096,
      contentType: 'application/vnd.apple.mpegurl',
      kind: engine.MediaKind.hls,
      site: 'ornek',
      createdAt: 0,
    ));
    expect(item.size, 4096);
    expect(captureKindLabel(item.kind), 'HLS');
  });

  test('onay sirasi tek pencere gosterir', () {
    final queue = HandoffQueue();
    queue.request('a');
    queue.request('b');
    queue.request('a'); // ayni gorev iki kez siralanmaz

    expect(queue.take(), 'a');
    expect(queue.take(), isNull); // 'a'nin penceresi henuz kapanmadi
    expect(queue.sync(['a', 'b']), isNull);

    queue.close('a');
    expect(queue.take(), 'b');
  });

  test('onay sirasi listeyi izler', () {
    final queue = HandoffQueue();
    queue.request('a');
    queue.request('b');
    queue.take(); // 'a' penceresi acik

    // 'a' baska bir yerden onaylandi: yetim kalan pencere bildirilir.
    expect(queue.sync(['b']), 'a');
    expect(queue.shown, isNull);
    // Kapanis haberi gecikse bile siradakinin yerini almaz.
    queue.close('a');
    expect(queue.take(), 'b');

    queue.request('c');
    // Gorev listeden dustu: pencere kapanir, sira bosalmis olur.
    expect(queue.sync(['b', 'c']), isNull);
    queue.close('b');
    expect(queue.take(), 'c');
    // Eski pencerenin gec kapanis haberi yeniyi dusurmez.
    queue.close('b');
    expect(queue.shown, 'c');
  });

  test('kopru hatasinin kisa aciklamasi', () {
    expect(engineReason(Exception('Gorev bulunamadi')), 'Gorev bulunamadi');
  });

  test('sayi alanlari 1..16 arasinda kalir', () {
    expect(parseCount('5', 3), 5);
    expect(parseCount('', 3), 3);
    expect(parseCount('bir', 8), 8);
    expect(parseCount('0', 3), 1);
    expect(parseCount('40', 3), 16);
  });

  test('tema ayari taninan degerlere iner', () {
    expect(themeModeSetting(themeModeFrom(' dark ')), 'dark');
    expect(themeModeSetting(themeModeFrom('LIGHT')), 'light');
    // Eski ayar dosyalarinda alan yok; elle duzenlenen deger de varsayilana
    // duser, cunku motordaki `normalize_theme` ayni kumeyi tanir.
    expect(themeModeSetting(themeModeFrom('')), 'system');
    expect(themeModeSetting(themeModeFrom('sepya')), 'system');
  });

  testWidgets('mod degisince pencere agaci yeni paleti okur', (tester) async {
    applyThemeMode(ThemeMode.light);
    await tester.pumpWidget(_settingsHost(const Center(child: _PaletteProbe())));
    expect(_probeColor(tester), const Color(0xFFFFFFFF));

    applyThemeMode(ThemeMode.dark);
    await tester.pump();
    expect(_probeColor(tester), const Color(0xFF1D1F1B));
  });

  testWidgets('ayarlar paneli gorunum seceneklerini gosterir', (tester) async {
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        onSaved: (_) {},
      ),
    ));

    expect(find.text('GÖRÜNÜM'), findsOneWidget);
    expect(find.text('Sistem'), findsOneWidget);
    expect(find.text('Aydınlık'), findsOneWidget);
    expect(find.text('Karanlık'), findsOneWidget);
  });

  testWidgets('secilen gorunum hemen boyanir', (tester) async {
    applyThemeMode(ThemeMode.light);
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        onSaved: (_) {},
      ),
    ));

    await tester.tap(find.text('Karanlık'));
    await tester.pump();
    expect(Serene.brightness, Brightness.dark);
  });

  testWidgets('kaydedilmeden kapanan panel tema denemesini geri alir', (
    tester,
  ) async {
    applyThemeMode(ThemeMode.light);
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: Settings(
          downloadDir: r'C:\indir',
          maxConcurrent: 3,
          connections: 8,
          watchClipboard: false,
          closeToTray: true,
          confirmBrowserDownload: true,
          theme: 'light',
        ),
        onClose: () {},
        onSaved: (_) {},
      ),
    ));

    await tester.tap(find.text('Karanlık'));
    await tester.pump();
    expect(Serene.brightness, Brightness.dark);

    // Kaydetmeden kapanis: secim yalnizca denemeydi, kayitli deger doner.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(Serene.brightness, Brightness.light);
  });

  testWidgets('ayarlar paneli motor ayarlarindan dolar', (tester) async {
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        onSaved: (_) {},
      ),
    ));

    expect(find.text('Ayarlar'), findsOneWidget);
    expect(find.text(r'C:\indir'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
  });

  testWidgets('ayarlar paneli Esc ile kapanir', (tester) async {
    var closed = 0;
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () => closed++,
        onSaved: (_) {},
      ),
    ));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('tepsi ayari satira tiklaninca cevrilir', (tester) async {
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        onSaved: (_) {},
      ),
    ));

    final boxes = find.byType(Checkbox);
    expect(tester.widget<Checkbox>(boxes.at(1)).value, isTrue);
    await tester.tap(find.text('Kapatınca tepsiye gizle'));
    await tester.pump();
    expect(tester.widget<Checkbox>(boxes.at(1)).value, isFalse);
  });
}

/// Panel tek basina da ayni temayi seesin: katmanin sahibi ana pencere gibi.
Widget _settingsHost(Widget child) =>
    MaterialApp(theme: sereneTheme(Brightness.light), home: child);

Color? _probeColor(WidgetTester tester) {
  final box = tester.widget<Container>(find.byKey(_PaletteProbe.boxKey));
  return (box.decoration as BoxDecoration).color;
}

/// Ana pencerenin tema mekanizmasinin kucuk kopyasi: modu dinler ve kendi
/// `build`ini yeniden calistirir. Palet global oldugu icin yeni renkleri
/// ancak agaci yeniden kuran dugum gorebilir.
class _PaletteProbe extends StatefulWidget {
  const _PaletteProbe();

  static const boxKey = ValueKey('palet-yoklamasi');

  @override
  State<_PaletteProbe> createState() => _PaletteProbeState();
}

class _PaletteProbeState extends State<_PaletteProbe> {
  @override
  void initState() {
    super.initState();
    appThemeMode.addListener(_onTheme);
  }

  @override
  void dispose() {
    appThemeMode.removeListener(_onTheme);
    super.dispose();
  }

  void _onTheme() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: _PaletteProbe.boxKey,
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: Serene.surfaceContainerLowest),
    );
  }
}
