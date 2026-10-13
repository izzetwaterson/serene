import 'dart:io';

import 'package:flutter/scheduler.dart';

/// Kare zamanlayici teshisi.
///
/// Yalnizca `SERENE_FPS` ortam degiskeni verildiginde calisir; normal kosumda
/// hicbir maliyeti yoktur. Her kare icin UI (build) ve GPU (raster) suresini
/// milisaniye olarak stdout'a yazar; "hangi ekran kac ms" boylece objektif
/// olculur. 60 FPS butcesi ~16,7 ms; bunun uzeri takilma hissidir.
void startFrameLogging() {
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds / 1000.0;
      final raster = t.rasterDuration.inMicroseconds / 1000.0;
      final total = t.totalSpan.inMicroseconds / 1000.0;
      stdout.writeln(
        'FRAME b=${build.toStringAsFixed(1)} r=${raster.toStringAsFixed(1)} '
        't=${total.toStringAsFixed(1)}',
      );
      // Ilk kare isaretlenir: `probe` onu "pencere cizildi" anı sayar.
      if (!_firstFrameLogged) {
        _firstFrameLogged = true;
        bootMark('first-frame');
      }
    }
  });
}

bool _firstFrameLogged = false;

/// Acilis asamalarinin saniyeli olcumu.
///
/// Ayni sekilde yalnizca `SERENE_FPS` verildiginde yazar. Amac: "ilk kare neden
/// gec geliyor" sorusunu tahmine birakmamak. Satirlar `BOOT <etiket> t=<ms>`
/// bicimindedir ve sure `main()`in ilk satirindan isler; kosum betigi sureci
/// baslatip ilk `BOOT main` satirina kadar gecen zamani da olcup motur.
final Stopwatch _boot = Stopwatch();

/// `SERENE_FPS` verilmisse acilis saati burada baslar ve `main` isaretlenir.
void startBootProbe() {
  if (!_perfEnabled) return;
  _boot
    ..reset()
    ..start();
  bootMark('main');
}

bool get _perfEnabled => Platform.environment['SERENE_FPS'] != null;

/// Bir acilis asamasi yazar. Bayrak yoksa hicbir sey yapmaz ve olcmez.
void bootMark(String label) {
  if (!_perfEnabled) return;
  stdout.writeln('BOOT $label t=${_boot.elapsedMilliseconds}');
}
