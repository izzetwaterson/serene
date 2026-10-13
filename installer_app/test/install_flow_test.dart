// Kurulum ve kaldirma AKISI: registry yazimlari, dosya kopyalama/silme sirasi
// ve veri koruma karari. `HostOps` sahtesiyle OS'a dokunmadan sınanir; tum
// dosyalar geçici bir klasorde yasar.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:serene_setup/setup_logic.dart';

/// Windows yan etkilerinin sahtesi: registry/powershell cagrilarini yalnizca
/// kaydeder, serene calismiyor der, veri dizinini geçici yola yonlendirir.
class FakeHost extends HostOps {
  FakeHost();

  final List<List<String>> regCalls = [];
  final List<String> psCalls = [];
  bool running = false;
  String dataDirPath = '';

  @override
  Future<ProcessResult> reg(List<String> args) async {
    regCalls.add(args);
    // `query` cagrisi: deger yoksa (Run kaydi yok) exitCode 1 doner.
    if (args.isNotEmpty && args.first == 'query') {
      return ProcessResult(0, 1, '', '');
    }
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<ProcessResult> powershell(String script) async {
    psCalls.add(script);
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<bool> isSereneRunning() async => running;

  @override
  Future<void> killHelper() async {
    // Testte OS'a dokunma; kopyalama yeniden denemesi sahte surecte calisir.
  }

  @override
  String dataDir() => dataDirPath;
}

void main() {
  late Directory tmp;
  late Directory payload;
  late Directory self;
  late FakeHost host;
  late String dir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('serene-inst-');
    payload = Directory('${tmp.path}\\payload')..createSync(recursive: true);
    self = Directory('${tmp.path}\\self')..createSync(recursive: true);
    File('${payload.path}\\Serene.exe').writeAsStringSync('APP');
    File('${payload.path}\\rust_lib_serene.dll').writeAsStringSync('LIB');
    // Kaldirici, kurulum uygulamasinin kendi klasorunden kopyalanir.
    File('${self.path}\\SereneSetup.exe').writeAsStringSync('SETUP');
    dir = '${tmp.path}\\Programs\\Serene';
    host = FakeHost()..dataDirPath = '${tmp.path}\\data';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> install({bool autostart = false}) async {
    final installer = Installer(
      payloadDir: payload.path,
      version: '1.0.0',
      host: host,
      selfDir: self.path,
    );
    final options = SetupOptions(dir: dir, startMenu: false, desktop: false, autostart: autostart, language: 'tr');
    await installer.install(options, (_, __, ___) {});
  }

  test('kurulum: payload kopyalanir, manifest + dil + kaldirici yazilir', () async {
    await install();

    expect(File('$dir\\Serene.exe').readAsStringSync(), 'APP');
    expect(File('$dir\\rust_lib_serene.dll').readAsStringSync(), 'LIB');
    expect(File('$dir\\uninstall\\install.manifest').existsSync(), isTrue);
    expect(File('$dir\\uninstall\\lang.txt').readAsStringSync(), 'tr');
    expect(File('$dir\\uninstall\\SereneSetup.exe').existsSync(), isTrue);

    // Uninstall registry girdileri (Programlar ve Ozellikler) yazildi.
    expect(host.regCalls.any((c) => c.first == 'add' && c.contains(regUninstallKey)), isTrue);
    expect(host.regCalls.any((c) => c.contains('DisplayName')), isTrue);
    expect(host.regCalls.any((c) => c.contains('UninstallString')), isTrue);
  });

  test('kurulum: autostart yalnizca istenirse yazilir', () async {
    await install();
    expect(host.regCalls.any((c) => c.first == 'add' && c.contains(regRunKey)), isFalse);

    host.regCalls.clear();
    dir = '${tmp.path}\\Programs\\Serene2';
    await install(autostart: true);
    expect(host.regCalls.any((c) => c.first == 'add' && c.contains(regRunKey)), isTrue);
  });

  test('kaldirma: dosyalar ve registry silinir, veri korunur', () async {
    await install();
    Directory(host.dataDir()).createSync(recursive: true);
    File('${host.dataDir()}\\ayar.json').writeAsStringSync('{}');
    host.regCalls.clear();

    await Uninstaller(host: host).uninstall(dir, keepData: true, report: (_, __, ___) {});

    expect(File('$dir\\Serene.exe').existsSync(), isFalse);
    expect(File('$dir\\rust_lib_serene.dll').existsSync(), isFalse);
    expect(host.regCalls.any((c) => c.first == 'delete' && c.contains(regUninstallKey)), isTrue);
    // Varsayilan: kullanici verisi korunur.
    expect(Directory(host.dataDir()).existsSync(), isTrue);
    expect(File('${host.dataDir()}\\ayar.json').existsSync(), isTrue);
  });

  test('kaldirma --delete-data: veri dizini de silinir', () async {
    await install();
    Directory(host.dataDir()).createSync(recursive: true);

    await Uninstaller(host: host).uninstall(dir, keepData: false, report: (_, __, ___) {});

    expect(Directory(host.dataDir()).existsSync(), isFalse);
  });

  test('Serene calisirken kurulum ve kaldirma reddedilir', () async {
    host.running = true;
    await expectLater(install(), throwsA(isA<SetupFailure>()));
    await expectLater(
      Uninstaller(host: host).uninstall(dir, keepData: true, report: (_, __, ___) {}),
      throwsA(isA<SetupFailure>()),
    );
  });

  test('kaldirma gecici klasorleri budar ama uninstall klasorune dokunmaz', () async {
    await install();
    // Bos bir alt klasor birak; kaldirmada budanmali.
    Directory('$dir\\data\\bos')..createSync(recursive: true);

    await Uninstaller(host: host).uninstall(dir, keepData: true, report: (_, __, ___) {});

    expect(Directory('$dir\\data\\bos').existsSync(), isFalse);
    // Kaldiricinin kendi klasoru kalir (scheduleSelfRemoval ayri bir .bat ile siler).
    expect(Directory('$dir\\uninstall').existsSync(), isTrue);
  });
}
