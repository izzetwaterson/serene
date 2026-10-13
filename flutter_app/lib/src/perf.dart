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
    }
  });
}
