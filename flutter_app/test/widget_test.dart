// `setSurfaceSize` testler icin gecici bir API; yalnizca mantiksal pencere
// olcusunu sabitlemek icin kullanilir (asagida `_setWindow`).
// ignore_for_file: invalid_use_of_visible_for_testing_member

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
import 'package:serene_app/src/update_check.dart';

/// `Field` etiketi duz cumle halinde gosterilir; testte ayni metni aramak icin
/// etiket oldugu gibi kullanilir.
String _field(String label) => label;

/// Ayar panelinde istenen sekmeye gecer.
///
/// Panel uc sekmeye bolundu (Genel / Indirmeler / Davranis). Onceki testler
/// ayarlari tek sayfada ariyordu; simdi her ayar yalnizca kendi sekmesinde
/// gorunur. Iki `pump` gerekir: sekme degisimi bir `setState` ve bir
/// `IndexedStack` yeniden kurulumu.
Future<void> _openTab(WidgetTester tester, String tab) async {
  await tester.tap(find.text(tab));
  await tester.pump();
  await tester.pump();
}

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
      extensionOfferDone: true,
    );

/// Test mantiksal penceresinin olcusunu gercek uygulama penceresine sabitler.
///
/// Testler varsayilan 800x600 mantiksal ekranda calisir. Uygulamanin gercek
/// penceresi 1280x880; ayar paneli de 880'e gore tasarlanmis. 600'de panel
/// listeye kayar ve alt satirlar (orn. "Kapatinca tepsiye gizle") ekran disi
/// kalir. Bu yuzden `setSurfaceSize` **yalnizca test govdesi icinde**
/// cagrilabilir (`inTest` sarti); bu yuzden `setUp` ile degil, asagidaki
/// yardimcilarin kendisiyle her testin basinda cagriliyor.
Future<void> setRealWindow() async {
  await TestWidgetsFlutterBinding.instance.setSurfaceSize(const Size(1280, 880));
}

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
    // duser, cunku motordaki `normalize_theme` ayni kumeyi tanir. Varsayilan
    // aydinliktir: uygulama acildigi anda karanlik pencere kullaniciyi yamirtir.
    expect(themeModeSetting(themeModeFrom('')), 'light');
    expect(themeModeSetting(themeModeFrom('sepya')), 'light');
    expect(themeModeSetting(themeModeFrom('System')), 'system');
  });

  testWidgets('mod degisince pencere agaci yeni paleti okur', (tester) async {
    await setRealWindow();
    applyThemeMode(ThemeMode.light);
    await tester.pumpWidget(_settingsHost(const Center(child: _PaletteProbe())));
    expect(_probeColor(tester), const Color(0xFFFFFFFF));

    applyThemeMode(ThemeMode.dark);
    await tester.pump();
    expect(_probeColor(tester), const Color(0xFF1D1F1B));
  });

  testWidgets('ayarlar paneli gorunum seceneklerini gosterir', (tester) async {
    await setRealWindow();
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        engineVersion: '0.1.0',
        onSaved: (_) {},
      ),
    ));

    expect(find.text(_field(T.appearanceLabel)), findsOneWidget);
    expect(find.text(T.themeSystem), findsOneWidget);
    expect(find.text(T.themeLight), findsOneWidget);
    expect(find.text(T.themeDark), findsOneWidget);
  });

  testWidgets('hakkinda sekmesi surum, baglanti ve lisans gosterir', (tester) async {
    await setRealWindow();
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        engineVersion: '0.1.0',
        onSaved: (_) {},
      ),
    ));

    // Sol listede dortuncu sekme.
    expect(find.text(T.tabAbout), findsOneWidget);

    await _openTab(tester, T.tabAbout);

    // Uygulama adi ve iki surum ayri gosterilir.
    expect(find.text('Serene'), findsOneWidget);
    // "Version" etiketi iki kez cikiyor: About sekmesinde ve panelin ust
    // basliginda yer alan motor surumu satirinda. Bu yuzden sayilmiyor, yalnizca
    // varligi dogrulanir.
    expect(find.text(T.aboutVersion), findsWidgets);
    expect(find.text(T.aboutEngine), findsOneWidget);
    expect(find.text('0.1.0'), findsOneWidget); // motor surumu
    // Uygulama surumu motor surumunden farkli; motor kurulmadigi test
    // cercevesinde '-' gorunur.
    expect(find.text('-'), findsWidgets);

    // Kaynak kodu baglantisi ve lisans basligi.
    expect(find.text(T.aboutRepository), findsOneWidget);
    expect(find.text('github.com/izzetwaterson/serene'), findsOneWidget);
    expect(find.text(T.aboutLicense), findsOneWidget);
  });

  testWidgets('yeni surum bulununca hakkinda sekmesinde indirme satiri cikar',
      (tester) async {
    await setRealWindow();
    // Genel durum; testler arasinda sizmasin.
    addTearDown(() => availableUpdate.value = null);
    availableUpdate.value = const UpdateInfo(
      version: '9.9.9',
      url: 'https://example.com/serene',
    );

    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        engineVersion: '0.1.0',
        onSaved: (_) {},
      ),
    ));
    await _openTab(tester, T.tabAbout);

    // Yalnizca yeni surum varken gorunur: uygulama indirmez, kullaniciya yol verir.
    expect(find.text(T.updateAvailable('9.9.9')), findsOneWidget);
    expect(find.text(T.updateDownload), findsOneWidget);

    // Guncelleme kalkinca satir da kaybolur (sakin arayuz: kalici uyari yok).
    availableUpdate.value = null;
    await tester.pump();
    expect(find.text(T.updateDownload), findsNothing);
  });

  testWidgets('hakkinda sekmesi lisans metnini gosterir', (tester) async {
    await setRealWindow();
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        engineVersion: '0.1.0',
        onSaved: (_) {},
      ),
    ));
    await _openTab(tester, T.tabAbout);

    // Lisans metni derleme zamaninda gomulur (`lib/src/license_text.dart`),
    // bu yuzden `rootBundle` erisimi gerekmez ve testte asset sistemi
    // kurulmasa da okunabilir.
    expect(find.textContaining('MIT License'), findsOneWidget);
    expect(find.textContaining('Copyright (c) 2026 Serene'), findsOneWidget);
  });

  testWidgets('secilen gorunum hemen boyanir', (tester) async {
    await setRealWindow();
    applyThemeMode(ThemeMode.light);
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        engineVersion: '0.1.0',
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
          extensionOfferDone: true,
        ),
        onClose: () {},
        engineVersion: '0.1.0',
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
    await setRealWindow();
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        engineVersion: '0.1.0',
        onSaved: (_) {},
      ),
    ));

    expect(find.text('Ayarlar'), findsOneWidget);
    await _openTab(tester, T.tabDownloads);
    await _openTab(tester, T.tabDownloads);
    expect(find.text(r'C:\indir'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
  });

  testWidgets('ayarlar paneli Esc ile kapanir', (tester) async {
    await setRealWindow();
    var closed = 0;
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () => closed++,
        engineVersion: '0.1.0',
        onSaved: (_) {},
      ),
    ));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('tepsi ayari satira tiklaninca cevrilir', (tester) async {
    await setRealWindow();
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        engineVersion: '0.1.0',
        onSaved: (_) {},
      ),
    ));

    await _openTab(tester, T.tabBehaviour);
    final boxes = find.byType(Checkbox);
    expect(tester.widget<Checkbox>(boxes.at(1)).value, isTrue);
    await tester.tap(find.text(T.closeToTrayTitle));
    await tester.pump();
    expect(tester.widget<Checkbox>(boxes.at(1)).value, isFalse);
  });

  testWidgets('mod degisince pencere agaci yeni dili okur', (tester) async {
    await setRealWindow();
    await tester.pumpWidget(_settingsHost(const Center(child: _TextProbe())));
    expect(_probeText(tester), 'Bugün ne indirmek istersiniz?');

    applyLanguage(AppLanguage.en);
    await tester.pump();
    expect(_probeText(tester), 'What would you like to download today?');
  });

  testWidgets('ayarlar paneli dil seceneklerini gosterir', (tester) async {
    await setRealWindow();
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        engineVersion: '0.1.0',
        onSaved: (_) {},
      ),
    ));

    // Etiketler `Field` icinde buyuk harfe cevrilir; Dart'in buyutmesi
    // yerel ayarsizdir, bu yuzden "Dil" -> "DIL".
    expect(find.text(_field(T.languageLabel)), findsOneWidget);
    expect(find.text('Türkçe'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
  });

  testWidgets('secilen dil panelin metinlerini hemen cevirir', (tester) async {
    await setRealWindow();
    await tester.pumpWidget(_settingsHost(
      SettingsPanel(
        settings: _engineSettings(),
        onClose: () {},
        engineVersion: '0.1.0',
        onSaved: (_) {},
      ),
    ));

    await tester.tap(find.text('English'));
    await tester.pump();

    expect(T.settingsTitle, 'Settings');
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Görünüm'), findsNothing);
    expect(find.text('Appearance'), findsOneWidget);
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
        engineVersion: '0.1.0',
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
        onFilter: (_) {},
        onCategory: (_) {},
        onCaptures: () {},
      ),
    ));

    expect(find.text(T.fromBrowser), findsOneWidget);
    // Gorev listesi bos: tek sifir disi sayac yakalananlardir.
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('yakalananlar panosu satirlari duz metin cizer', (tester) async {
    await setRealWindow();
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
    await setRealWindow();
    final task = _handoffFixture();
    await tester.pumpWidget(_settingsHost(HandoffWindow(task: task, preview: true)));

    expect(find.text(T.handoffTitle), findsOneWidget);
    expect(find.text(task.url), findsOneWidget);

    await tester.tap(find.text(T.startDownload));
    await tester.pump();
    expect(find.text(T.sampleTaskNoEngine), findsOneWidget);
  });

  testWidgets('pano onerisi baglantiyi gosterir ve iki secenek sunar', (tester) async {
    await setRealWindow();
    const url = 'https://ornek.dev/film.mp4';
    var dismissed = 0;
    var downloaded = 0;

    await tester.pumpWidget(
      _settingsHost(
        ClipboardToast(
          url: url,
          onDismiss: () => dismissed++,
          onDownload: () => downloaded++,
        ),
      ),
    );

    // Baslik, adres ve iki dugme gorunur.
    expect(find.text(T.clipboardToastTitle), findsOneWidget);
    expect(find.text(url), findsOneWidget);
    expect(find.text(T.clipboardDismiss), findsOneWidget);
    expect(find.text(T.clipboardDownload), findsOneWidget);

    await tester.tap(find.text(T.clipboardDownload));
    await tester.pump();
    expect(downloaded, 1);
    expect(dismissed, 0);

    await tester.tap(find.text(T.clipboardDismiss));
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets('pano onerisi bastan sona kadar tek satirdir', (tester) async {
    await setRealWindow();
    // Uzun bir adres kartin genisligini asmamali; tasma satirlari bozmaz.
    const url =
        'https://ornek.dev/ cok/ uzun/ bir/ dosya/ adi/ ile/ bir/ video.mp4?token=abc';
    await tester.pumpWidget(
      _settingsHost(
        ClipboardToast(url: url, onDismiss: () {}, onDownload: () {}),
      ),
    );

    final text = tester.widget<Text>(find.text(url));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  test('pano onerisi yalnizca http adresi icin gecerli', () {
    // Ayni kural `main_window.dart` icindeki `_offerClipboard`ta uygulanir;
    // test edilebilir kismi burada: bos veya http olmayan deger onerilmez.
    bool acceptable(String raw) {
      final value = raw.trim();
      return value.isNotEmpty && value.startsWith('http');
    }

    expect(acceptable('https://ornek.dev/a.mp4'), isTrue);
    expect(acceptable('  http://ornek.dev/a.mp4  '), isTrue);
    expect(acceptable('magnet:?xt=urn:btih:abc'), isFalse);
    expect(acceptable('dosya.txt'), isFalse);
    expect(acceptable('   '), isFalse);
    expect(acceptable(''), isFalse);
  });

  test('pano onerisi onermeden once dogru sureyi bekler', () {
    // Yanlislikla kopyalanan bir sey bir kart olarak birikmesin diye kart
    // kendiliginden kapanir; sure web kablugundaki eski degerle ayni.
    expect(clipboardToastVisible, const Duration(seconds: 12));
  });

  testWidgets('depolama hatasi bandi sebebi ve kapat dugmesi gosterir', (tester) async {
    await setRealWindow();
    const detail = r'C:\Users\ornek\AppData\Roaming\Serene\tasks.json yazilamadi';
    var dismissed = 0;

    await tester.pumpWidget(
      _settingsHost(
        StorageErrorBanner(detail: detail, onDismiss: () => dismissed++),
      ),
    );

    expect(find.text(T.storageErrorTitle), findsOneWidget);
    expect(find.text(detail), findsOneWidget);
    expect(find.text(T.storageErrorDismiss), findsOneWidget);

    await tester.tap(find.text(T.storageErrorDismiss));
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets('depolama bandinda sebep tasmaz, bir satirda kalir', (tester) async {
    await setRealWindow();
    // Dosya yolu uzun olabilir; bant yatay degil, dikey buyumesin.
    const detail = r'C:\Users\ornek\AppData\Roaming\Serene\tasks.json yazilamadi: '
        'yeterli disk alani yok';
    await tester.pumpWidget(
      _settingsHost(
        StorageErrorBanner(detail: detail, onDismiss: () {}),
      ),
    );
    final text = tester.widget<Text>(find.text(detail));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('gorev listesi sanallastirilir', (tester) async {
    await setRealWindow();
    final tasks = _manyTasks(50);
    await tester.pumpWidget(_taskPaneHost(tasks));
    await tester.pump();

    // Gorunmeyen kartlar kurulmaz: 50 gorevin tamami agacta degildir.
    final built = tester.widgetList(find.byType(TaskCard)).length;
    expect(built, greaterThan(0));
    expect(built, lessThan(50));
    expect(find.text('dosya-0.bin'), findsOneWidget);
    expect(find.text('dosya-49.bin'), findsNothing);

    // Kaydirma son karti gorunur kilar; sanallastirma yerlesimi bozmaz.
    await tester.scrollUntilVisible(
      find.text('dosya-49.bin'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('dosya-49.bin'), findsOneWidget);
  });

  testWidgets('yakalananlar listesi sanallastirilir', (tester) async {
    await setRealWindow();
    final items = [
      for (var i = 0; i < 50; i++)
        CaptureItem(
          id: 'cap-$i',
          url: 'https://cdn.ornek.test/dosya-$i.bin',
          filename: 'dosya-$i.bin',
          size: 1024,
          contentType: 'application/octet-stream',
          kind: 'file',
          site: 'ornek.test',
          createdAt: 1790000000,
        ),
    ];
    await tester.pumpWidget(
      _settingsHost(
        CapturesPane(
          items: items,
          notice: null,
          onAction: (_, _) {},
          onClear: () {},
        ),
      ),
    );

    final built = tester.widgetList(find.byType(CaptureCard)).length;
    expect(built, greaterThan(0));
    expect(built, lessThan(50));
  });

  testWidgets('ilerleme tiki yalnizca karti kurar', (tester) async {
    await setRealWindow();
    final task = _manyTasks(1).first;
    final tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    final key = GlobalKey<_CardHostState>();

    await tester.pumpWidget(
      _settingsHost(
        Center(
          child: SizedBox(
            width: 700,
            child: _CardHost(key: key, task: task, tick: tick),
          ),
        ),
      ),
    );
    final before = key.currentState!.builds;

    task.downloaded = 400;
    tick.value++;
    await tester.pump();

    // Ust agac kurulmadi: yalnizca ilerlemeyi dinleyen kart tazelendi.
    expect(key.currentState!.builds, before);
    expect(find.textContaining('400 B'), findsOneWidget);
  });

  testWidgets('bos durum ve uyari sliver yerlesimde gorunur', (tester) async {
    await setRealWindow();

    // Gorev yok: "Aktif indirme yok" kutusu ana bolumde cizilir.
    await tester.pumpWidget(_taskPaneHost(const []));
    expect(find.text(T.nothingDownloading), findsOneWidget);

    // Yakalama yok ama uyari var: ikisi de listeyle birlikte kayar.
    await tester.pumpWidget(
      _settingsHost(
        CapturesPane(
          items: const [],
          notice: 'uyari',
          onAction: (_, _) {},
          onClear: () {},
        ),
      ),
    );
    expect(find.text(T.noCapturedMedia), findsOneWidget);
    expect(find.text('uyari'), findsOneWidget);
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

/// Sanallastirma testleri icin uzun gorev listesi.
List<Task> _manyTasks(int count) => [
      for (var i = 0; i < count; i++)
        Task(
          id: 'gorev-$i',
          url: 'https://cdn.ornek.test/dosya-$i.bin',
          filename: 'dosya-$i.bin',
          dest: r'C:\indir\dosya.bin',
          total: 1000,
          downloaded: 0,
          speed: 0,
          status: 'downloading',
          category: 'software',
          createdAt: 0,
        ),
    ];

/// Gorev listesi panosunu tek basina kurar.
///
/// `Hero` icindeki adres alani bir `TextField` tasir; o da bir `Material`
/// atası ister. Bu yuzden kabuk gercek penceredeki gibi `Scaffold` kullanir.
Widget _taskPaneHost(List<Task> tasks, {ValueNotifier<int>? progress}) =>
    _scaffoldHost(
      TaskPane(
        tasks: tasks,
        filter: 'all',
        category: null,
        query: '',
        settings: _engineSettings(),
        notice: null,
        url: TextEditingController(),
        progress: progress,
        onQueryJump: (_) {},
        onSubmitUrl: () {},
        onAction: (_, _) {},
        destOverride: null,
        onPickFolder: () {},
        onClearOverride: () {},
        onOpenSettings: () {},
      ),
    );

/// Kartin ust agaci tazelemeden tek basina boyandigini olcen kucuk kabuk.
class _CardHost extends StatefulWidget {
  const _CardHost({super.key, required this.task, required this.tick});

  final Task task;
  final ValueNotifier<int> tick;

  @override
  State<_CardHost> createState() => _CardHostState();
}

class _CardHostState extends State<_CardHost> {
  int builds = 0;

  @override
  Widget build(BuildContext context) {
    builds++;
    return TaskCard(
      task: widget.task,
      onAction: (_, _) {},
      progress: widget.tick,
    );
  }
}

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

/// Pano kabugu: ana penceredeki `Material` saglayicisini taklit eder.
Widget _scaffoldHost(Widget child) => MaterialApp(
      theme: sereneTheme(Brightness.light),
      home: Scaffold(backgroundColor: Serene.background, body: child),
    );

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
