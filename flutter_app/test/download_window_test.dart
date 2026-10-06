// Ayri indirme penceresinin gorunumu: toplam ilerleme, parca barlari ve
// durum/eylem degisimleri. `fetch` enjekte edilerek motor gerekmez.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:serene_app/src/data.dart';
import 'package:serene_app/src/download_window.dart';
import 'package:serene_app/src/format.dart';
import 'package:serene_app/src/strings.dart';

const int _mb = 1024 * 1024;

Task _task({
  String status = 'downloading',
  int total = 32 * _mb,
  int downloaded = 16 * _mb,
  List<UiSegment> segments = const [],
}) => Task(
  id: 'gorev',
  url: 'https://ornek.test/buyuk.bin',
  filename: 'buyuk.bin',
  dest: r'C:\indir\buyuk.bin',
  total: total,
  downloaded: downloaded,
  speed: 1.2 * _mb,
  status: status,
  category: 'other',
  createdAt: 0,
  segments: segments,
);

List<UiSegment> _parts(int count, int size) => [
  for (var i = 0; i < count; i++)
    UiSegment(
      index: i,
      start: i * size,
      end: (i + 1) * size - 1,
      downloaded: 0,
    ),
];

Widget _window(Task? Function() task) => MaterialApp(
  home: DownloadWindow(id: 'gorev', fetch: (_) async => task()),
);

Future<void> _close(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());

void main() {
  setUp(() => applyLanguageSetting('en'));

  testWidgets('dosya, yuzde ve parca barlari cizilir', (tester) async {
    await tester.pumpWidget(_window(() => _task(segments: _parts(8, 4 * _mb))));
    await tester.pump();
    await tester.pump();

    expect(find.text('buyuk.bin'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('8 connections'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('tek parcali indirmede parca satiri cizilmez', (tester) async {
    await tester.pumpWidget(_window(() => _task(segments: _parts(1, 32 * _mb))));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('connections'), findsNothing);

    await _close(tester);
  });

  testWidgets('listede olmayan gorev bunu bildirir', (tester) async {
    await tester.pumpWidget(_window(() => null));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('no longer'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('tamamlanan indirmenin eylemi Pause degildir', (tester) async {
    await tester.pumpWidget(
      _window(() => _task(status: 'completed', downloaded: 32 * _mb)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Pause'), findsNothing);
    expect(find.text('Completed'), findsWidgets);

    await _close(tester);
  });

  testWidgets('duraklatilmis indirmenin eylemi Resume olur', (tester) async {
    await tester.pumpWidget(_window(() => _task(status: 'paused')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Pause'), findsNothing);

    await _close(tester);
  });

  test('segmentRatio parca dolulugunu ve bilinmeyen boyutu ele alir', () {
    expect(
      segmentRatio(UiSegment(index: 0, start: 0, end: 99, downloaded: 50)),
      closeTo(0.5, 1e-9),
    );
    expect(
      segmentRatio(UiSegment(index: 0, start: 0, end: 99, downloaded: 0)),
      0,
    );
    // Boyut bilinmiyor: yalnizca "bayt alindi mi" bilgisi kalir.
    expect(
      segmentRatio(
        UiSegment(index: 0, start: 0, end: unknownSegmentEnd, downloaded: 0),
      ),
      0,
    );
    expect(
      segmentRatio(
        UiSegment(index: 0, start: 0, end: unknownSegmentEnd, downloaded: 5),
      ),
      1,
    );
  });
}
