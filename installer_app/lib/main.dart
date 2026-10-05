import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'controller.dart';
import 'pages.dart';
import 'setup_logic.dart';
import 'strings.dart';
import 'theme.dart';

/// Serene kurulum / kaldirma uygulamasi.
///
/// Tek exe iki is yapar:
///   * `SereneSetup.exe`                 -> kurulum (varsayilan)
///   * `SereneSetup.exe --uninstall`     -> kaldirma (`<kurulum>\uninstall\` icinden)
///   * `--silent` ile arayuz hic cizilmeden calisir.
Brightness? _forcedBrightness;

Future<void> main(List<String> rawArgs) async {

  WidgetsFlutterBinding.ensureInitialized();
  final args = SetupArgs.parse(rawArgs);

  // Sessiz kip: Flutter kosucusu pencereyi ilk kare cizilince gosterir;
  // hic cizmedigimiz icin hicbir pencere gorunmez.
  if (args.silent) {
    exit(await _runSilent(args));
  }

  // `--theme light|dark` yalniz onizleme icindir; normalde sistem temasi izlenir.
  final themeFlag = rawArgs.indexOf('--theme');
  final forced = themeFlag >= 0 && themeFlag + 1 < rawArgs.length ? rawArgs[themeFlag + 1] : null;
  _forcedBrightness = forced == 'light'
      ? Brightness.light
      : forced == 'dark'
          ? Brightness.dark
          : null;
  Serene.activate(_forcedBrightness ?? ui.PlatformDispatcher.instance.platformBrightness);

  // Dil: `--lang` > kurulumda saklanan (kaldirma) > sistem. Etkilesimli kurulumda
  // ilk sayfa dili sorar ve bunu ezer.
  if (args.lang != null) {
    L.use(args.lang == 'tr');
  } else if (args.uninstall) {
    final saved = Uninstaller.savedLanguage();
    if (saved != null) L.use(saved == 'tr');
  }

  await windowManager.ensureInitialized();
  final options = WindowOptions(
    size: setupWindowSize,
    center: true,
    backgroundColor: Serene.background,
    title: L.current.setupTitle,
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    await windowManager.setTitle(L.current.setupTitle);
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(SetupApp(controller: SetupController(args)));
}

Future<int> _runSilent(SetupArgs args) async {

  try {
    if (await isSereneRunning()) await killSerene();
    if (args.uninstall) {
      final dir = Uninstaller.installDir();
      if (dir == null) return 1;
      await Uninstaller().uninstall(dir, keepData: args.keepData, report: (_, _, _) {});
      await Uninstaller.scheduleSelfRemoval(dir);
      return 0;
    }
    final installer = Installer(payloadDir: args.payload, version: args.version);
    final options = SetupOptions(
      dir: args.dir ?? defaultInstallDir(),
      startMenu: args.startMenu,
      autostart: args.autostart,
      language: args.lang ?? (L.systemIsTurkish ? 'tr' : 'en'),
    );
    await installer.install(options, (_, _, _) {});
    return 0;
  } on SetupFailure catch (e) {
    _logFailure(e.message);
    return 1;
  } catch (e) {
    _logFailure(e.toString());
    return 1;
  }
}

/// Arayuzsuz kipte hatayi gorecek kimse yok (GUI exe'nin stderr'i bos);
/// `%TEMP%\serene-setup.log` dosyasina yazilir. Temp yazilamazsa (kisitli
/// ortam) exe'nin yanina `SereneSetup.log` yazilir.
void _logFailure(String message) {
  final line = '${DateTime.now().toIso8601String()} $message\n';
  final custom = Platform.environment['SERENE_SETUP_LOG'];
  try {
    final path = custom ?? '${Directory.systemTemp.path}\\serene-setup.log';
    File(path).writeAsStringSync(line, mode: FileMode.append);
  } catch (_) {
    try {
      File('${Platform.resolvedExecutable}.log').writeAsStringSync(line, mode: FileMode.append);
    } catch (_) {}
  }
}

class SetupApp extends StatefulWidget {
  const SetupApp({super.key, required this.controller});

  final SetupController controller;

  @override
  State<SetupApp> createState() => _SetupAppState();
}

class _SetupAppState extends State<SetupApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_rebuild);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  @override
  void didChangePlatformBrightness() {
    Serene.activate(_forcedBrightness ?? ui.PlatformDispatcher.instance.platformBrightness);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: L.current.setupTitle,
      theme: sereneTheme(Serene.brightness),
      home: Scaffold(
        backgroundColor: Serene.background,
        body: SetupShell(controller: widget.controller),
      ),
    );
  }
}
