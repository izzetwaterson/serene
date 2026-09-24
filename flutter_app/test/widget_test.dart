import 'package:flutter_test/flutter_test.dart';

import 'package:serene_app/src/data.dart';
import 'package:serene_app/src/format.dart';

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
}
