import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_theme.dart';
import 'src/data.dart';
import 'src/download_window.dart';
import 'src/handoff_window.dart';
import 'src/main_window.dart';
// Motor koprusu; `Task` adi eskiden dosya okuyan katmanla carpistigi icin
// simdilik onekli cagriliyor. Arayüz tamamen FFI'ye gecince ek kalkacak.
import 'src/rust/api/commands.dart' as ffi;
import 'src/rust/api/events.dart' as ffi;
import 'src/rust/api/lifecycle.dart' as ffi;
import 'src/rust/frb_generated.dart';
import 'src/strings.dart';
import 'src/theme.dart';

/// Iki kip:
///   Serene.exe                    -> ana pencere (main window)
///   `Serene.exe --demo`           -> ana pencere ornek gorevlerle acilir
///   `Serene.exe --settings`       -> ana pencere ayarlar katmani acik halde
///   `Serene.exe --handoff=<b64>`  -> ayri "İndirme Bilgileri" penceresi
///        (`--handoff-theme=system|light|dark` ile o pencerenin temasi)
///        (`--handoff-lang=tr|en` ile o pencerenin dili)
///   `Serene.exe --download=<id>`  -> ayri canli indirme penceresi
///        (`--download-theme=...`, `--download-lang=...` ayni bicimde)
///   `Serene.exe --selfcheck`      -> pencere acmadan Rust motorunu yoklar
///
/// Onay penceresi kendi surecinde acilir; boylece gercek bir isletim sistemi
/// penceresi olur ve ana pencere kapanip acilsa da bagimsiz kalir. Ayarlar
/// yalnizca ana pencerenin motorunda durur; onay penceresi tema ve dili komut
/// satirindan alir.
Future<void> main(List<String> args) async {
  if (args.contains('--selfcheck')) {
    await _selfcheck();
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final payload = _arg(args, 'handoff');
  if (payload != null) {
    // Dil yuk cozulmeden once kurulur: bozuk yukteki "bilinmeyen indirme"
    // metni ve pencere basligi bu degeri okur.
    applyLanguageSetting(_arg(args, 'handoff-lang') ?? 'en');
    await _openHandoff(
      _decodeTask(payload),
      preview: args.contains('--handoff-demo'),
      theme: _arg(args, 'handoff-theme') ?? 'light',
    );
    return;
  }

  final downloadId = _arg(args, 'download');
  if (downloadId != null) {
    applyLanguageSetting(_arg(args, 'download-lang') ?? 'en');
    await _openDownload(
      downloadId,
      theme: _arg(args, 'download-theme') ?? 'light',
    );
    return;
  }

  await _openMain(
    demo: args.contains('--demo'),
    settings: args.contains('--settings'),
  );
}

/// Köprü yoklaması: derlenen Rust kütüphanesi yükleniyor mu, motor kendi
/// verisi olmadan ayağa kalkıyor mu, bir komut gidip geliyor mu ve çekirdek
/// olayı Dart'a ulaşıyor mu? Koşum bu satırı ve sıfır çıkış kodunu bekler.
///
/// Yoklama gerçek görev listesine dokunmasın diye yalıtılmış bir veri klasörü
/// zorunludur; motor orada boş bir listeyle kurulur.
Future<void> _selfcheck() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dataDir = Platform.environment['SERENE_DATA_DIR'];
  if (dataDir == null || dataDir.isEmpty) {
    stderr.writeln(
      'KOPRU HATA: SERENE_DATA_DIR tanımlı değil (yalıtılmış yoklama)',
    );
    exit(2);
  }

  try {
    await RustLib.init();
    await ffi.bootEngine();

    final version = ffi.engineVersion();
    // Abone olunduktan sonra yayınlanan ilk olay, akışın canlı olduğunu kanıtlar:
    // aynı ayarları yeniden yazmak her seferinde tam liste yayını tetikler.
    final events = ffi.watchTasks();
    final config = await ffi.updateSettings(settings: ffi.getSettings());
    final tasks = await events.first.timeout(const Duration(seconds: 5));

    ffi.stopBridge();
    stdout.writeln(
      'KOPRU motor=$version gorev=${tasks.length} eszamanli=${config.maxConcurrent}',
    );
    exit(0);
  } catch (error) {
    stderr.writeln('KOPRU HATA: $error');
    exit(1);
  }
}

Future<void> _openMain({bool demo = false, bool settings = false}) async {
  // Motor pencereden once kurulur: ilk kare bos listeyle boyanmasın.
  await RustLib.init();

  // Tek ornek: calisan bir Serene varsa onun penceresi one gelir ve bu surec
  // hic motor kurmadan cikar; iki motor ayni gorev listesine yazamaz.
  // Cikis `exit` ile: Windows kosucusu Dart main'den once pencereyi acar,
  // yalnizca donmek bos bir pencere birakirdi.
  if (ffi.handOffToRunning()) exit(0);

  await ffi.bootEngine();

  // Palet ve metinler pencereden once kurulur: `backgroundColor` ve ilk kare,
  // kayitli temayi ve dili gormeli. Ayarlar okunamazsa varsayilanlar kalir.
  try {
    final saved = ffi.getSettings();
    applyThemeSetting(saved.theme);
    applyLanguageSetting(saved.language);
  } catch (_) {
    /* ayar okunamadi: varsayilanlarla devam */
  }

  final options = WindowOptions(
    size: Size(1280, 880),
    minimumSize: Size(940, 620),
    center: true,
    backgroundColor: Serene.background,
    title: T.appTitle,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(true);
    await windowManager.setTitle(T.appTitle);
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(SereneApp(demo: demo, settings: settings));

  // Firefox native messaging kaydi ikilinin yolunu gosterir; surum
  // yukseltmesinde degistigi icin her acilista tazele. Gelistirme derlemesinin
  // yaninda serene-nmh.exe yoktur, kayit defterine dokunmadan basarisiz olur.
  // `SERENE_DATA_DIR` yaliniz yoklama icin verilir: o kipte kopru kaydi gecici
  // klasorde durur, tarayici ise gercek klasore bakar. Bu yuzden yoklama sirasi
  // tarayiciyi kendine baglamamali.
  if (Platform.environment['SERENE_DATA_DIR'] == null) {
    try {
      ffi.registerBrowserHost();
    } catch (_) {
      /* kayit zorunlu degil: eklenti olmadan da indirme baslar */
    }
  }
}

/// Onay penceresi: motoru olan tek surec ana penceredir. Bu kip yalnizca
/// derlenen kopru kutuphanesini yukler ve karari calisan ornege yollar.
/// Tema komut satirindan gelir: ayar dosyasini yalnizca ana pencere okur.
Future<void> _openHandoff(
  Task task, {
  required bool preview,
  required String theme,
}) async {
  await RustLib.init();
  applyThemeSetting(theme);

  final options = WindowOptions(
    size: Size(460, 600),
    center: true,
    backgroundColor: Serene.surfaceContainerLowest,
    skipTaskbar: true,
    alwaysOnTop: true,
    title: T.handoffTitle,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setTitle(T.handoffTitle);
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(HandoffApp(task: task, preview: preview));
}

/// Canli indirme penceresi: onay penceresi gibi ayri bir surectir ve kendi
/// motorunu kurmaz; gorevi calisan ornekten kopru uzerinden okur.
Future<void> _openDownload(String id, {required String theme}) async {
  await RustLib.init();
  applyThemeSetting(theme);

  final options = WindowOptions(
    size: Size(520, 560),
    center: true,
    backgroundColor: Serene.surfaceContainerLowest,
    title: T.downloadTitle,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(false);
    await windowManager.setTitle(T.downloadTitle);
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(DownloadApp(id: id));
}

String? _arg(List<String> args, String name) {
  final prefix = '--$name=';
  for (final value in args) {
    if (value.startsWith(prefix)) return value.substring(prefix.length);
  }
  return null;
}

Task _decodeTask(String payload) {
  try {
    // `normalize` dolguyu tamamlar: yuku ureten taraf `base64Url.encode`
    // olsa da olmasa da ayni komut elle calistirilabilir kalsin.
    final json = utf8.decode(base64Url.decode(base64Url.normalize(payload)));
    return Task.fromJson(jsonDecode(json) as Map<String, dynamic>);
  } catch (_) {
    return Task(
      id: 'unknown',
      url: '',
      filename: T.unknownDownload,
      dest: '',
      total: 0,
      downloaded: 0,
      speed: 0,
      status: 'paused',
      category: 'other',
      createdAt: 0,
      pending: true,
    );
  }
}

class SereneApp extends StatelessWidget {
  const SereneApp({super.key, this.demo = false, this.settings = false});

  final bool demo;

  /// Ana pencereyle birlikte ayarlar katmanini acar (`--settings`).
  final bool settings;

  @override
  Widget build(BuildContext context) {
    // `themeMode` degisince `MaterialApp` yeniden kurulur; paleti kullanan
    // govde agaci da ondan kopyalandigi icin guncel renkleri okur.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: T.appTitle,
        debugShowCheckedModeBanner: false,
        theme: sereneTheme(Brightness.light),
        darkTheme: sereneTheme(Brightness.dark),
        themeMode: mode,
        home: MainWindow(demoOn: demo, settingsOn: settings),
      ),
    );
  }
}

class HandoffApp extends StatelessWidget {
  const HandoffApp({super.key, required this.task, this.preview = false});

  final Task task;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: T.handoffTitle,
        debugShowCheckedModeBanner: false,
        theme: sereneTheme(Brightness.light),
        darkTheme: sereneTheme(Brightness.dark),
        themeMode: mode,
        home: HandoffWindow(task: task, preview: preview),
      ),
    );
  }
}

class DownloadApp extends StatelessWidget {
  const DownloadApp({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: T.downloadTitle,
        debugShowCheckedModeBanner: false,
        theme: sereneTheme(Brightness.light),
        darkTheme: sereneTheme(Brightness.dark),
        themeMode: mode,
        home: DownloadWindow(id: id),
      ),
    );
  }
}
