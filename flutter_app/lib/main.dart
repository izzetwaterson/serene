import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/data.dart';
import 'src/handoff_window.dart';
import 'src/main_window.dart';
// Motor koprusu; `Task` adi eskiden dosya okuyan katmanla carpistigi icin
// simdilik onekli cagriliyor. Arayüz tamamen FFI'ye gecince ek kalkacak.
import 'src/rust/api/commands.dart' as ffi;
import 'src/rust/api/events.dart' as ffi;
import 'src/rust/api/lifecycle.dart' as ffi;
import 'src/rust/frb_generated.dart';
import 'src/theme.dart';

/// Iki kip:
///   serene_app.exe                 -> ana pencere (main window)
///   `serene_app.exe --demo`        -> ana pencere ornek gorevlerle acilir
///   `serene_app.exe --handoff=<b64>` -> ayri "İndirme Bilgileri" penceresi
///   `serene_app.exe --selfcheck`   -> pencere acmadan Rust motorunu yoklar
///
/// Onay penceresi kendi surecinde acilir; boylece gercek bir isletim sistemi
/// penceresi olur ve ana pencere kapanip acilsa da bagimsiz kalir.
Future<void> main(List<String> args) async {
  if (args.contains('--selfcheck')) {
    await _selfcheck();
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final payload = _arg(args, 'handoff');
  if (payload != null) {
    await _openHandoff(_decodeTask(payload));
    return;
  }
  await _openMain(demo: args.contains('--demo'));
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
    stderr.writeln('KOPRU HATA: SERENE_DATA_DIR tanımlı değil (yalıtılmış yoklama)');
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

Future<void> _openMain({bool demo = false}) async {
  const options = WindowOptions(
    size: Size(1280, 880),
    minimumSize: Size(940, 620),
    center: true,
    backgroundColor: Serene.background,
    title: 'Serene',
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(true);
    await windowManager.setTitle('Serene');
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(SereneApp(demo: demo));
}

Future<void> _openHandoff(Task task) async {
  const options = WindowOptions(
    size: Size(520, 680),
    center: true,
    backgroundColor: Serene.surfaceContainerLowest,
    skipTaskbar: true,
    alwaysOnTop: true,
    title: 'İndirme Bilgileri',
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setTitle('İndirme Bilgileri');
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(HandoffApp(task: task));
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
    final json = utf8.decode(base64Url.decode(payload));
    return Task.fromJson(jsonDecode(json) as Map<String, dynamic>);
  } catch (_) {
    return Task(
      id: 'unknown',
      url: '',
      filename: 'Bilinmeyen indirme',
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
  const SereneApp({super.key, this.demo = false});

  final bool demo;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Serene',
      debugShowCheckedModeBanner: false,
      theme: sereneTheme(),
      home: MainWindow(demoOn: demo),
    );
  }
}

class HandoffApp extends StatelessWidget {
  const HandoffApp({super.key, required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'İndirme Bilgileri',
      debugShowCheckedModeBanner: false,
      theme: sereneTheme(),
      home: HandoffWindow(task: task),
    );
  }
}
