import 'dart:convert';
import 'dart:io';

/// Kurulum ve kaldirmanin Windows'a dokunan butun isi burada. Arayuz yalnizca
/// bu siniflari cagirir; boylece ayni mantik sessiz kipte (`--silent`) arayuz
/// cizilmeden de calisir.
///
/// SOZLESME (eski NSIS paketiyle ayni, `core/src/platform.rs` ve
/// `native-host` ile uyumlu): kayit defteri adlari asagidadir; birini
/// degistirmek uygulamanin kendi otomatik baslatma / kopru kaydini bozar.

const appExe = 'Serene.exe';
const nmhExe = 'serene-nmh.exe';
const setupExe = 'SereneSetup.exe';

const regUninstallKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Serene';
const regRunKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const regRunValue = 'Serene';
const shortcutName = 'Serene.lnk';

/// Kaldirici dosyalarinin ve kurulan dosya listesinin durdugu alt klasor.
const uninstallDirName = 'uninstall';
const manifestName = 'install.manifest';
const languageFileName = 'lang.txt';

class SetupArgs {
  SetupArgs({
    required this.uninstall,
    required this.silent,
    required this.payload,
    required this.version,
    required this.dir,
    required this.startMenu,
    required this.autostart,
    required this.keepData,
    this.preview,
    this.lang,
  });

  final bool uninstall;
  final bool silent;
  final String payload;
  final String version;
  final String? dir;
  final bool startMenu;
  final bool autostart;
  final bool keepData;

  /// Gelistirici onizlemesi (`--page ADI`); normal kullanimda hep null.
  final String? preview;

  /// Arayuz dili (`--lang tr|en`). Verilirse dil sorusu atlanir.
  final String? lang;

  /// Desteklenen bayraklar: `--uninstall`, `--silent`, `--payload KLASOR`,
  /// `--version X.Y.Z`, `--dir KLASOR`, `--no-startmenu`, `--autostart`,
  /// `--delete-data`, `--lang tr|en`.
  factory SetupArgs.parse(List<String> args) {
    String? value(String name) {
      final i = args.indexOf(name);
      return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
    }

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return SetupArgs(
      uninstall: args.contains('--uninstall'),
      silent: args.contains('--silent'),
      payload: value('--payload') ?? '$exeDir\\..\\payload',
      version: value('--version') ?? '1.0.0',
      dir: value('--dir'),
      startMenu: !args.contains('--no-startmenu'),
      autostart: args.contains('--autostart'),
      keepData: !args.contains('--delete-data'),
      preview: value('--page'),
      lang: value('--lang'),
    );
  }
}

/// Varsayilan kurulum klasoru: `%LOCALAPPDATA%\Programs\Serene`.
String defaultInstallDir() {
  final base = Platform.environment['LOCALAPPDATA'] ??
      '${Platform.environment['USERPROFILE'] ?? r'C:\Users\Public'}\\AppData\\Local';
  return '$base\\Programs\\Serene';
}

/// Secilen klasorun SON parcasi `Serene` degilse altina `Serene` eklenir.
/// Boylece kullanici yanlislikla `Belgelerim` secse bile kaldirma yalnizca
/// kendi alt klasorunu siler.
String normalizeInstallDir(String chosen) {
  var path = chosen.trim().replaceAll('/', '\\');
  while (path.length > 3 && path.endsWith('\\')) {
    path = path.substring(0, path.length - 1);
  }
  final last = path.split('\\').last;
  if (last.toLowerCase() == 'serene') return path;
  return '$path\\Serene';
}

class SetupOptions {
  SetupOptions({
    required this.dir,
    this.startMenu = true,
    this.desktop = true,
    this.autostart = false,
    this.language = 'en',
  });

  String dir;
  bool startMenu;
  bool desktop;
  bool autostart;

  /// `tr` ya da `en`; kaldirici ayni dilde acilsin diye kurulumla birlikte saklanir.
  String language;
}

/// Kurulum/kaldirma adimi. Arayuz bunu metne cevirir.
enum SetupStep { files, register, shortcut, desktop, autostart, done, removeBridge, removeFiles, removeRegistry, removeData }

typedef ProgressCallback = void Function(double progress, SetupStep step, String detail);

class SetupFailure implements Exception {
  SetupFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/* ---------- Windows yardimcilari ---------- */

Future<ProcessResult> _reg(List<String> args) => Process.run('reg', args, runInShell: false);

/// PowerShell betigini `-EncodedCommand` ile calistirir. Betik UTF-16LE
/// base64 olarak gectigi icin tirnak/bosluk kacirma sorunu olmaz.
Future<ProcessResult> _powershell(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add((unit >> 8) & 0xFF);
  }
  return Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-EncodedCommand',
    base64.encode(bytes),
  ]);
}

/// Serene.exe calisiyor mu? `tasklist /FO CSV` ilk karakteri tirnak olan bir
/// satir verir; "gorev yok" mesaji dile gore degistigi icin metne degil bu
/// karaktere bakilir.
Future<bool> isSereneRunning() async {
  try {
    final result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq $appExe', '/NH', '/FO', 'CSV']);
    return result.stdout.toString().trimLeft().startsWith('"');
  } catch (_) {
    return false;
  }
}

Future<void> killSerene() async {
  await Process.run('taskkill', ['/IM', appExe, '/F']);
  // Dosya kilitlerinin birakilmasi icin kisa bir bekleme.
  for (var i = 0; i < 20; i++) {
    if (!await isSereneRunning()) return;
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
}

String _startMenuShortcutPath() {
  final appData = Platform.environment['APPDATA'] ?? '';
  return '$appData\\Microsoft\\Windows\\Start Menu\\Programs\\$shortcutName';
}

String _dataDir() => '${Platform.environment['APPDATA'] ?? ''}\\Serene';

/* ---------- kurulum ---------- */

class Installer {
  Installer({required this.payloadDir, required this.version});

  final String payloadDir;
  final String version;

  /// Kurulum paketinde dosya var mi (taşıyıcı dogru acmis mi).
  bool get payloadPresent => File('$payloadDir\\$appExe').existsSync();


  List<File> _payloadFiles() => Directory(payloadDir)
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList(growable: false);

  /// Kurulum sonunda uygulamayi baslatir (arayuzden baglantisini keser).
  static Future<void> launch(String dir) async {
    await Process.start('$dir\\$appExe', const [],
        workingDirectory: dir, mode: ProcessStartMode.detached);
  }

  Future<void> install(SetupOptions options, ProgressCallback report) async {
    final dir = normalizeInstallDir(options.dir);
    options.dir = dir;

    if (!payloadPresent) {
      throw SetupFailure('Setup files are missing: $payloadDir');
    }
    if (await isSereneRunning()) {
      throw SetupFailure('Serene is still running.');
    }

    final files = _payloadFiles();
    final total = files.fold<int>(0, (sum, f) => sum + f.lengthSync());

    // 1) Eski kurulumun artiklari: kendi dosya listesine gore (yoksa bilinen adlar).
    report(0, SetupStep.files, '');
    await _removeOldFiles(dir);

    // 2) Dosyalari kopyala. Ilerleme bayt sayisina gore; %0-80 arasi.
    final installed = <String>[];
    var done = 0;
    await Directory(dir).create(recursive: true);
    for (final file in files) {
      final rel = _relative(file.path, payloadDir);
      final target = File('$dir\\$rel');
      await target.parent.create(recursive: true);
      await file.copy(target.path);
      installed.add(rel);
      done += await file.length();
      report(total == 0 ? 0.8 : 0.8 * done / total, SetupStep.files, rel);
    }

    // 3) Kaldirici = bu uygulamanin kendi klasorunun kopyasi.
    final uninstallDir = '$dir\\$uninstallDirName';
    await Directory(uninstallDir).create(recursive: true);
    await _copyBundle(Directory(File(Platform.resolvedExecutable).parent.path), Directory(uninstallDir));
    await File('$uninstallDir\\$manifestName').writeAsString(installed.join('\n'), encoding: utf8);
    await File('$uninstallDir\\$languageFileName').writeAsString(options.language);

    // 4) Programlar ve Ozellikler kaydi.
    report(0.84, SetupStep.register, '');
    await _writeUninstallEntry(dir, total);

    if (options.startMenu) {
      report(0.88, SetupStep.shortcut, '');
      await _createShortcut(dir);
    }

    if (options.desktop) {
      report(0.90, SetupStep.desktop, '');
      await _createDesktopShortcut(dir);
    }

    if (options.autostart) {
      report(0.92, SetupStep.autostart, '');
      // Deger tirnakli mutlak yol: `core/src/platform.rs` `run_value` ile ayni.
      await _reg(['add', regRunKey, '/v', regRunValue, '/t', 'REG_SZ', '/d', '"$dir\\$appExe"', '/f']);
    }

    report(1, SetupStep.done, '');
  }

  Future<void> _removeOldFiles(String dir) async {
    final root = Directory(dir);
    if (!root.existsSync()) return;
    final manifest = File('$dir\\$uninstallDirName\\$manifestName');
    final old = manifest.existsSync()
        ? manifest.readAsLinesSync(encoding: utf8).where((l) => l.trim().isNotEmpty).toList()
        : <String>[...await _knownNames(), ...await _dataFiles(dir)];
    for (final rel in old) {
      try {
        final file = File('$dir\\$rel');
        if (file.existsSync()) await file.delete();
      } catch (_) {
        // Kilitli dosya: ustune yazma asamasi hatayi acikca bildirir.
      }
    }
    await _pruneEmptyDirs(root);
  }

  Future<List<String>> _knownNames() async => [
        appExe,
        nmhExe,
        'rust_lib_serene.dll',
        'flutter_windows.dll',
        'cnativeapi.dll',
        'screen_retriever_windows_plugin.dll',
        'window_manager_plugin.dll',
        'LICENSE.txt',
        'THIRD_PARTY_LICENSES.md',
        'Uninstall.exe',
      ];

  /// `data\` altindaki dosyalar (eski NSIS kurulumu liste tutmaz).
  Future<List<String>> _dataFiles(String dir) async {
    final data = Directory('$dir\\data');
    if (!data.existsSync()) return const [];
    return data
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => _relative(f.path, dir))
        .toList();
  }

  Future<void> _writeUninstallEntry(String dir, int totalBytes) async {
    final uninstaller = '$dir\\$uninstallDirName\\$setupExe';
    final values = <List<String>>[
      ['DisplayName', 'REG_SZ', 'Serene'],
      ['DisplayVersion', 'REG_SZ', version],
      ['Publisher', 'REG_SZ', 'Serene'],
      ['DisplayIcon', 'REG_SZ', '$dir\\$appExe'],
      ['InstallLocation', 'REG_SZ', dir],
      ['UninstallString', 'REG_SZ', '"$uninstaller" --uninstall'],
      ['QuietUninstallString', 'REG_SZ', '"$uninstaller" --uninstall --silent'],
      ['NoModify', 'REG_DWORD', '1'],
      ['NoRepair', 'REG_DWORD', '1'],
      ['EstimatedSize', 'REG_DWORD', '${(totalBytes / 1024).round()}'],
    ];
    for (final v in values) {
      final result = await _reg(['add', regUninstallKey, '/v', v[0], '/t', v[1], '/d', v[2], '/f']);
      if (result.exitCode != 0) {
        throw SetupFailure('Registry write failed (${v[0]}): ${result.stderr}');
      }
    }
  }

  Future<void> _createShortcut(String dir) async {
    final lnk = _startMenuShortcutPath().replaceAll("'", "''");
    final exe = '$dir\\$appExe'.replaceAll("'", "''");
    final work = dir.replaceAll("'", "''");
    await _powershell('''
\$shell = New-Object -ComObject WScript.Shell
\$s = \$shell.CreateShortcut('$lnk')
\$s.TargetPath = '$exe'
\$s.WorkingDirectory = '$work'
\$s.IconLocation = '$exe,0'
\$s.Save()
''');
  }

  /// Masaustu yolu PowerShell ile cozulur: OneDrive yonlendirmesini de bilir.
  Future<void> _createDesktopShortcut(String dir) async {
    final exe = '$dir\\$appExe'.replaceAll("'", "''");
    final work = dir.replaceAll("'", "''");
    await _powershell('''
\$desktop = [Environment]::GetFolderPath('Desktop')
\$shell = New-Object -ComObject WScript.Shell
\$s = \$shell.CreateShortcut((Join-Path \$desktop '$shortcutName'))
\$s.TargetPath = '$exe'
\$s.WorkingDirectory = '$work'
\$s.IconLocation = '$exe,0'
\$s.Save()
''');
  }

}

/* ---------- kaldirma ---------- */

class Uninstaller {
  /// Kurulu klasor: bu exe `<dir>\uninstall\` icinden calisir.
  static String? installDir() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    if (exeDir.path.split('\\').last.toLowerCase() == uninstallDirName) {
      return exeDir.parent.path;
    }
    return null;
  }

  /// Kurulumda secilen dil (`tr`/`en`); dosya yoksa null (sistem dili kullanilir).
  static String? savedLanguage() {
    final dir = installDir();
    if (dir == null) return null;
    try {
      final text = File('$dir\\$uninstallDirName\\$languageFileName').readAsStringSync().trim();
      return text == 'tr' || text == 'en' ? text : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> uninstall(String dir, {required bool keepData, required ProgressCallback report}) async {
    if (await isSereneRunning()) {
      throw SetupFailure('Serene is still running.');
    }

    // 1) Tarayici koprusu: kayit defteri + manifest. Dosyalar silinmeden once.
    report(0.1, SetupStep.removeBridge, '');
    final host = File('$dir\\$nmhExe');
    if (host.existsSync()) {
      try {
        await Process.run(host.path, ['--unregister-host']);
      } catch (_) {
        // Kaydi baska bir kurulum yazmis olabilir; sessizce gec.
      }
    }

    // Otomatik baslatma yalnizca bize aitse silinir (tasinabilir kopyanin kaydi kalir).
    final query = await _reg(['query', regRunKey, '/v', regRunValue]);
    if (query.exitCode == 0 && query.stdout.toString().contains('$dir\\$appExe')) {
      await _reg(['delete', regRunKey, '/v', regRunValue, '/f']);
    }

    // 2) Kisayol ve dosyalar.
    report(0.35, SetupStep.removeFiles, '');
    final shortcut = File(_startMenuShortcutPath());
    if (shortcut.existsSync()) await shortcut.delete();
    try {
      await _powershell('''
\$desktop = [Environment]::GetFolderPath('Desktop')
\$lnk = Join-Path \$desktop '$shortcutName'
if (Test-Path \$lnk) { Remove-Item -LiteralPath \$lnk -Force }
''');
    } catch (_) {
      // Masaustu cozulemezse kaldirma devam eder.
    }

    final manifest = File('$dir\\$uninstallDirName\\$manifestName');
    final listed = manifest.existsSync()
        ? manifest.readAsLinesSync(encoding: utf8).where((l) => l.trim().isNotEmpty).toList()
        : <String>[];
    var removed = 0;
    for (final rel in listed) {
      final file = File('$dir\\$rel');
      try {
        if (file.existsSync()) await file.delete();
      } catch (_) {
        throw SetupFailure('Could not remove: $rel');
      }
      removed++;
      report(0.35 + 0.4 * removed / listed.length, SetupStep.removeFiles, rel);
    }
    await _pruneEmptyDirs(Directory(dir), skip: uninstallDirName);

    // 3) Windows kayitlari.
    report(0.8, SetupStep.removeRegistry, '');
    await _reg(['delete', regUninstallKey, '/f']);

    // 4) Kullanici verisi: yalnizca acikca istenirse.
    if (!keepData) {
      report(0.9, SetupStep.removeData, '');
      final data = Directory(_dataDir());
      if (data.existsSync()) await data.delete(recursive: true);
    }

    report(1, SetupStep.done, '');
  }

  /// Kaldirici kendi klasorunu calisirken silemez. Uygulama kapaninca bir
  /// toplu is dosyasi `uninstall\` klasorunu ve (bossa) kurulum klasorunu siler.
  static Future<void> scheduleSelfRemoval(String dir) =>
      scheduleCleanup(removeTrees: ['$dir\\$uninstallDirName'], removeIfEmpty: [dir]);
}

/// Calisan surec kapaninca silinebilecek klasorler icin ayrik bir toplu is
/// dosyasi baslatir. Dosyalar surec cikana kadar kilitli oldugundan silme
/// birkac kez denenir. `removeIfEmpty` yalnizca bossa siler (kullanici
/// dosyasi olabilecek bir klasor zorla silinmez).
Future<void> scheduleCleanup({List<String> removeTrees = const [], List<String> removeIfEmpty = const []}) async {
  final lines = StringBuffer('@echo off\r\n');
  for (final tree in removeTrees) {
    lines
      ..write('for /l %%i in (1,1,15) do (\r\n')
      ..write('  rmdir /s /q "$tree" 2>nul\r\n')
      ..write('  if not exist "$tree" goto next_${removeTrees.indexOf(tree)}\r\n')
      ..write('  ping 127.0.0.1 -n 2 >nul\r\n')
      ..write(')\r\n')
      ..write(':next_${removeTrees.indexOf(tree)}\r\n');
  }
  for (final dir in removeIfEmpty) {
    lines.write('rmdir "$dir" 2>nul\r\n');
  }
  lines.write('del "%~f0"\r\n');
  final bat = File('${Directory.systemTemp.path}\\serene-cleanup-${DateTime.now().microsecondsSinceEpoch}.bat');
  await bat.writeAsString(lines.toString());
  await Process.start('cmd.exe', ['/c', bat.path], mode: ProcessStartMode.detached);
}

/* ---------- ortak ---------- */

String _relative(String path, String root) {
  var r = root.replaceAll('/', '\\');
  if (!r.endsWith('\\')) r = '$r\\';
  final p = path.replaceAll('/', '\\');
  return p.toLowerCase().startsWith(r.toLowerCase()) ? p.substring(r.length) : p;
}

/// Alt klasorlerden bosalanlari asagidan yukari siler. `skip` adli ilk
/// seviye klasore dokunmaz (calisan kaldirici).
Future<void> _pruneEmptyDirs(Directory root, {String? skip}) async {
  if (!root.existsSync()) return;
  final dirs = root.listSync(recursive: true).whereType<Directory>().toList()
    ..sort((a, b) => b.path.length.compareTo(a.path.length));
  for (final d in dirs) {
    if (skip != null && d.path.toLowerCase().contains('\\${skip.toLowerCase()}')) continue;
    try {
      if (d.listSync().isEmpty) await d.delete();
    } catch (_) {}
  }
}

Future<void> _copyBundle(Directory from, Directory to) async {
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    // Hata ayiklama gunlukleri kaldiriciya tasinmaz.
    if (entity.path.toLowerCase().endsWith('.log')) continue;
    final rel = _relative(entity.path, from.path);
    final target = File('${to.path}\\$rel');
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  }
}
