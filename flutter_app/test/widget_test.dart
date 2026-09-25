import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:serene_app/src/app_theme.dart';
import 'package:serene_app/src/cards.dart';
import 'package:serene_app/src/data.dart';
import 'package:serene_app/src/format.dart';
import 'package:serene_app/src/handoff.dart';
import 'package:serene_app/src/handoff_window.dart';
import 'package:serene_app/src/main_window.dart';
import 'package:serene_app/src/rust/api/dto.dart' as engine;
import 'package:serene_app/src/settings_view.dart';
import 'package:serene_app/src/strings.dart';
import 'package:serene_app/src/theme.dart';

Settings _engineSettings() => Settings(
      downloadDir: r'C:\indir',
      maxConcurrent: 3,
      connections: 8,
      watchClipboard: false,
      closeToTray: true,
      confirmBrowserDownload: true,
      theme: 'system',
      language: 'tr',
      autostart: false,
    );

void main() {
  // Palet ve metinler globaldir; bir testin biraktigi secim digerine sizmasin.
  tearDown(() {
    applyThemeMode(ThemeMode.system);
    applyLanguage(AppLanguage.tr);
  });

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
          language: 'tr',
          autostart: false,
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

  testWidgets('mod degisince pencere agaci yeni dili okur', (tester) async {
    await tester.pumpWidget(_settingsHost(const Center(child: _TextProbe())));
    expect(_probeText(tester), 'Bugün ne indirmek istersiniz?');

    applyLanguage(AppLanguage.en);
    await tester.pump();
    expect(_probeText(tester), 'What would you like to download today?');
  });

  testWidgets('ayarlar paneli dil seceneklerini gosterir', (tester) async {
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        onSaved: (_) {},
      ),
    ));

    // Etiketler `Field` icinde buyuk harfe cevrilir; Dart'in buyutmesi
    // yerel ayarsizdir, bu yuzden "Dil" -> "DIL".
    expect(find.text('DIL'), findsOneWidget);
    expect(find.text('Türkçe'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
  });

  testWidgets('secilen dil panelin metinlerini hemen cevirir', (tester) async {
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        onSaved: (_) {},
      ),
    ));

    await tester.tap(find.text('English'));
    await tester.pump();

    expect(T.settingsTitle, 'Settings');
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('GÖRÜNÜM'), findsNothing);
    expect(find.text('APPEARANCE'), findsOneWidget);
    // Dilin kendi adi her iki dilde de ayni yazilir.
    expect(find.text('Türkçe'), findsOneWidget);
  });

  testWidgets('kaydedilmeden kapanan panel dil denemesini geri alir', (
    tester,
  ) async {
    applyLanguage(AppLanguage.tr);
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        onSaved: (_) {},
      ),
    ));

    await tester.tap(find.text('English'));
    await tester.pump();
    expect(appLanguage.value, AppLanguage.en);

    // Kaydetmeden kapanis: secim yalnizca denemeydi, kayitli dil doner.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(appLanguage.value, AppLanguage.tr);
  });

  testWidgets('kenar cubugu yakalananlar sayisini rozette gosterir', (
    tester,
  ) async {
    await tester.pumpWidget(_settingsHost(
      Sidebar(
        tasks: const [],
        captures: _captureFixtures(),
        settings: _engineSettings(),
        disk: null,
        filter: 'all',
        category: null,
        view: 'tasks',
        demoOn: false,
        onNewDownload: () {},
        onFilter: (_) {},
        onCategory: (_) {},
        onCaptures: () {},
        onDemo: (_) {},
      ),
    ));

    expect(find.text(T.fromBrowser), findsOneWidget);
    // Gorev listesi bos: tek sifir disi sayac yakalananlardir.
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('yakalananlar panosu satirlari duz metin cizer', (tester) async {
    final items = _captureFixtures();
    await tester.pumpWidget(_settingsHost(
      CapturesPane(
        items: items,
        notice: null,
        onAction: (_, _) {},
        onClear: () {},
      ),
    ));

    expect(find.text(T.mediaCount(2)), findsOneWidget);
    // Dosya adi HTML olarak yorumlanmaz: etiketler oldugu gibi gorunur.
    expect(find.text('<b>kotu</b>.mp4'), findsOneWidget);
    expect(find.text('serene-test.bin'), findsOneWidget);
    // Satir ust bilgisi site, boyut ve zamanla kurulur.
    expect(find.textContaining('ornek.test'), findsNWidgets(2));
  });

  testWidgets('onay penceresi onizlemede motoru cagirmaz', (tester) async {
    final task = _handoffFixture();
    await tester.pumpWidget(_settingsHost(HandoffWindow(task: task, preview: true)));

    expect(find.text(T.handoffTitle), findsOneWidget);
    expect(find.text(task.url), findsOneWidget);
    expect(find.text(r'C:\indir'), findsOneWidget);

    await tester.tap(find.text(T.startDownload));
    await tester.pump();
    expect(find.text(T.sampleTaskNoEngine), findsOneWidget);
  });
}

List<CaptureItem> _captureFixtures() => [
      CaptureItem(
        id: 'cap-1',
        url: 'https://cdn.ornek.test/<b>kotu</b>.mp4',
        filename: '<b>kotu</b>.mp4',
        size: 4 * 1024 * 1024,
        contentType: 'video/mp4',
        kind: 'file',
        site: 'ornek.test',
        createdAt: 1790000000,
      ),
      CaptureItem(
        id: 'cap-2',
        url: 'https://cdn.ornek.test/serene-test.bin',
        filename: 'serene-test.bin',
        size: 0,
        contentType: 'application/octet-stream',
        kind: 'file',
        site: 'ornek.test',
        createdAt: 1790000000,
      ),
    ];

Task _handoffFixture() => Task(
      id: 'gorev-1',
      url: 'https://cdn.ornek.test/devralinan.bin',
      filename: 'devralinan.bin',
      dest: r'C:\indir\devralinan.bin',
      total: 8 * 1024 * 1024,
      downloaded: 0,
      speed: 0,
      status: 'paused',
      category: 'software',
      createdAt: 1790000000,
      source: 'download',
      pending: true,
      resumable: true,
    );

/// Panel tek basina da ayni temayi seesin: katmanin sahibi ana pencere gibi.
Widget _settingsHost(Widget child) =>
    MaterialApp(theme: sereneTheme(Brightness.light), home: child);

Color? _probeColor(WidgetTester tester) {
  final box = tester.widget<Container>(find.byKey(_PaletteProbe.boxKey));
  return (box.decoration as BoxDecoration).color;
}

String _probeText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(_TextProbe.textKey)).data!;

/// Ana pencerenin dil mekanizmasinin kucuk kopyasi: metinler globaldir ve
/// degistiginde agac kendiliginden kurulmaz; dinleyen dugum `build`ini
/// yeniden calistirmali ki yeni metni okusun.
class _TextProbe extends StatefulWidget {
  const _TextProbe();

  static const textKey = ValueKey('metin-yoklamasi');

  @override
  State<_TextProbe> createState() => _TextProbeState();
}

class _TextProbeState extends State<_TextProbe> {
  @override
  void initState() {
    super.initState();
    appLanguage.addListener(_onLanguage);
  }

  @override
  void dispose() {
    appLanguage.removeListener(_onLanguage);
    super.dispose();
  }

  void _onLanguage() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Text(T.heroTitle, key: _TextProbe.textKey);
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
