import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

/// assets/fonts altindaki her yazi tipini FontLoader ile kayit eder.
Future<void> _loadAssets() async {
  for (final file in Directory('assets/fonts').listSync().whereType<File>()) {
    if (!file.path.endsWith('.ttf')) continue;
    final family = file.uri.pathSegments.last.replaceAll('.ttf', '');
    final bytes = Uint8List.fromList(await file.readAsBytes());
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}

/// Metni piksele cevirip ozet cikarir: dolu piksel sayisi, saglama toplami, olcu.
Future<String> _raster(String text, String family) async {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: family, fontSize: 40, color: const Color(0xFFFFFFFF)),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Offset.zero);
  final image = recorder.endRecording().toImageSync(
        painter.width.ceil() + 4,
        painter.height.ceil() + 4,
      );
  final data = (await image.toByteData(format: ImageByteFormat.rawRgba))!;
  final bytes = data.buffer.asUint8List();
  var opaque = 0, sum = 0;
  for (var i = 3; i < bytes.length; i += 4) {
    if (bytes[i] > 40) opaque++;
    sum = (sum + bytes[i]) % 1000000007;
  }
  return '${opaque}px/$sum';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('yazi tipleri gercek sfnt olarak kaydedilmis', () {
    // fontTools, woff2'den okudugu yazi tipini uzantiya bakmadan yine woff2
    // olarak yazar; Flutter bunu sessizce yok sayip test yazi typine duser.
    for (final file in Directory('assets/fonts').listSync().whereType<File>()) {
      if (!file.path.endsWith('.ttf')) continue;
      final bytes = File(file.path).readAsBytesSync().sublist(0, 4);
      expect(bytes, [0, 1, 0, 0], reason: '${file.path} sfnt degil');
    }
  });

  test('Material Symbols ciziliyor, yok sayilmiyor', () async {
    await _loadAssets();
    const spa = '\ueb4c';
    final rendered = await _raster(spa, 'MaterialSymbolsOutlined');
    final fallback = await _raster(spa, 'OlmayanAile');
    expect(rendered, isNot(fallback), reason: 'aile cozulmedi, yedek yazi typine dustu');
  });
}
