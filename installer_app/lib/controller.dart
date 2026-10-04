import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'setup_logic.dart';
import 'strings.dart';

enum SetupPage { language, welcome, options, installing, done, error, confirmUninstall, removing, removed }

/// Deneme yerlesimleri (karar verilene kadar).
///   card : yatay kucuk kart; solda yaprak, sagda icerik
///   calm : ortalanmis, tek sutunlu, daha da sade
///   flow : tek yuzey; yaprak madalyonu sabit, icerik ayni sahnede akar;
///          karsilama + ayarlar tek ekranda birlesir
///   editorial : kart yok; tipografi ve ince cizgiler dogrudan zeminde;
///               karsilama + ayarlar tek editoryal sayfada
///   mini  : en kucuk pencere; tek sayfa — klasor satiri, satir ici acilan
///           ayarlar ve tek dugme
///   wizard: solda numarali adim rayi (Dil, Kurulum, Bitti), sagda sayfa
///   quiz  : her ekranda tek soru; ustte nokta gostergesi, tek dugme
///   fluent: Windows'a yerli his — Segoe UI, kare kose, Fluent kontroller
enum SetupVariant { card, calm, flow, editorial, mini, wizard, quiz, fluent }

/// `--variant` bayragini cozer; verilmeyen ya da taninmayan ad `card`a duser.
SetupVariant resolveVariant(String? name) => SetupVariant.values
    .firstWhere((v) => v.name == name, orElse: () => SetupVariant.card);

/// Arayuzun tek durum kaynagi. Sayfa gecisleri, ilerleme ve hatalar burada;
/// widget'lar yalnizca dinler ve metot cagirir.
class SetupController extends ChangeNotifier {
  SetupController(this.args)
      : options = SetupOptions(
          dir: args.dir ?? defaultInstallDir(),
          startMenu: args.startMenu,
          autostart: args.autostart,
        ),
        installer = Installer(payloadDir: args.payload, version: args.version) {
    variant = resolveVariant(args.variant);
    options.language = L.current.isTurkish ? 'tr' : 'en';
    // Dil sorusu yalniz etkilesimli kurulumda sorulur; `--lang` ya da
    // onizleme bayragi verilirse atlanir. Kaldirma dili kurulumdan okur.
    page = (args.uninstall || args.lang != null || args.preview != null) ? SetupPage.welcome : SetupPage.language;
    if (args.uninstall) {
      uninstallDir = Uninstaller.installDir();
      if (uninstallDir == null) {
        page = SetupPage.error;
        error = 'notInstalled';
      } else {
        page = SetupPage.confirmUninstall;
      }
    }
    _applyPreview();
    _poll();
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _poll());
  }

  final SetupArgs args;
  final Installer installer;
  final SetupOptions options;
  late final SetupVariant variant;

  SetupPage page = SetupPage.welcome;
  double progress = 0;
  SetupStep step = SetupStep.files;
  String detail = '';
  String? error;
  bool launchAfter = true;
  bool keepData = true;
  bool sereneRunning = false;
  String? uninstallDir;
  Timer? _timer;

  /// Gelistirici bayragi `--page ADI`: ekran goruntusu almak icin bir sayfayi
  /// ornek durumla acar (yalniz arayuz; Windows'a hicbir sey yazmaz).
  void _applyPreview() {
    final name = args.preview;
    if (name == null) return;
    for (final p in SetupPage.values) {
      if (p.name == name) {
        page = p;
        progress = 0.62;
        step = p == SetupPage.removing ? SetupStep.removeFiles : SetupStep.files;
        detail = 'data\\flutter_assets\\fonts\\Fraunces-Regular.ttf';
        if (p == SetupPage.error) error = 'Registry write failed (DisplayName): Access is denied.';
      }
    }
  }

  bool get busy => page == SetupPage.installing || page == SetupPage.removing;

  /// Marka panelindeki halka yalniz is sirasinda gorunur.
  double? get ringProgress => busy ? progress : null;

  Future<void> _poll() async {
    if (busy) return;
    final running = await isSereneRunning();
    if (running != sereneRunning) {
      sereneRunning = running;
      notifyListeners();
    }
  }

  void go(SetupPage next) {
    page = next;
    notifyListeners();
  }

  /// Dil sayfasi: secim aninda arayuz o dile gecer.
  void selectLanguage(bool turkish) {
    L.use(turkish);
    _set(() => options.language = turkish ? 'tr' : 'en');
  }

  void toggleStartMenu(bool v) => _set(() => options.startMenu = v);
  void toggleDesktop(bool v) => _set(() => options.desktop = v);
  void toggleAutostart(bool v) => _set(() => options.autostart = v);
  void toggleLaunch(bool v) => _set(() => launchAfter = v);
  void toggleKeepData(bool v) => _set(() => keepData = v);
  void setDir(String dir) => _set(() => options.dir = dir);

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }

  Future<void> closeSerene() async {
    await killSerene();
    sereneRunning = await isSereneRunning();
    notifyListeners();
  }

  Future<void> startInstall() async {
    progress = 0;
    step = SetupStep.files;
    detail = '';
    error = null;
    go(SetupPage.installing);
    final stopwatch = Stopwatch()..start();
    try {
      await installer.install(options, _report);
      // Cok hizli bitse bile ilerleme halkasinin kapanisini gorsun.
      final remaining = 1100 - stopwatch.elapsedMilliseconds;
      if (remaining > 0) await Future<void>.delayed(Duration(milliseconds: remaining));
      go(SetupPage.done);
    } on SetupFailure catch (e) {
      error = e.message;
      go(SetupPage.error);
    } catch (e) {
      error = e.toString();
      go(SetupPage.error);
    }
  }

  Future<void> startUninstall() async {
    final dir = uninstallDir;
    if (dir == null) return;
    progress = 0;
    step = SetupStep.removeBridge;
    detail = '';
    error = null;
    go(SetupPage.removing);
    final stopwatch = Stopwatch()..start();
    try {
      await Uninstaller().uninstall(dir, keepData: keepData, report: _report);
      final remaining = 1100 - stopwatch.elapsedMilliseconds;
      if (remaining > 0) await Future<void>.delayed(Duration(milliseconds: remaining));
      go(SetupPage.removed);
    } on SetupFailure catch (e) {
      error = e.message;
      go(SetupPage.error);
    } catch (e) {
      error = e.toString();
      go(SetupPage.error);
    }
  }

  void _report(double value, SetupStep s, String d) {
    progress = value;
    step = s;
    detail = d;
    notifyListeners();
  }

  /// Bitir dugmesi: gerekirse uygulamayi ac, kaldiricinin kalintilarini sil, cik.
  Future<void> finish() async {
    if (page == SetupPage.done) {
      if (launchAfter) await Installer.launch(options.dir);
    } else if (page == SetupPage.removed) {
      final dir = uninstallDir;
      if (dir != null) await Uninstaller.scheduleSelfRemoval(dir);
    }
    exit(0);
  }

  /// Bitis ekrani secimi: 'Serene'i ac' -> true, 'Bitir' -> false.
  void finishWith(bool launch) {
    launchAfter = launch;
    finish();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
