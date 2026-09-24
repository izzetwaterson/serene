import 'package:flutter_test/flutter_test.dart';

import 'package:serene_app/src/data.dart';
import 'package:serene_app/src/format.dart';
import 'package:serene_app/src/rust/api/dto.dart' as engine;

void main() {
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
}
