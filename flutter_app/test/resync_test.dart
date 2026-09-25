// Yayindan dusmus olay (kuyruk tasmasi) kararlari.
//
// Buradaki yardimcilar saf: motor, kopru ya da pencere gerekmez. Amac, uc
// kurali gostermek - kayip paket yarim uygulanmaz, bayat indekse tik
// uygulanmaz, ayni kayip iki kez toparlanmaz.

import 'package:flutter_test/flutter_test.dart';

import 'package:serene_app/src/data.dart';
import 'package:serene_app/src/handoff.dart';
import 'package:serene_app/src/main_window.dart';
import 'package:serene_app/src/rust/api/dto.dart' as engine;

/// Motorun gorev kimligi UUID bicimindedir; bildirim isareti degil.
final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}'
  r'-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

engine.Progress _tick(String id, {int downloaded = 0, double speed = 0}) =>
    engine.Progress(id: id, downloaded: downloaded, total: 1000, speed: speed);

/// Motorun tasma bildirimi: gercek bir tik degil, kac olayin dustugunu tasiyan
/// ayirici bir kayit.
engine.Progress _lost(int missed) =>
    engine.Progress(id: lostEventsId, downloaded: missed, total: 0, speed: 0);

Task _task(String id, {bool pending = false}) => Task(
      id: id,
      url: 'https://ornek.test/$id.bin',
      filename: '$id.bin',
      dest: r'C:\indir\$id.bin',
      total: 1000,
      downloaded: 0,
      speed: 0,
      status: 'downloading',
      category: 'other',
      createdAt: 0,
      pending: pending,
    );

Map<String, Task> _index(List<Task> tasks) => {
      for (final task in tasks) task.id: task,
    };

void main() {
  test('bildirim isareti gercek bir gorev kimligiyle caprazlasmaz', () {
    // Sabit iki tarafin ayni degeri okudugu sozlesmedir; isaret UUID
    // biciminde olmadigi icin hicbir gorev ya da yakalama ile caprazlamaz.
    expect(lostEventsId.startsWith('__'), isTrue);
    expect(_uuid.hasMatch(lostEventsId), isFalse);
    // Pano bildirimi gercek bir adres degil.
    expect(lostLink.startsWith('http'), isFalse);
    // Gercek "pencereyi one getir" istegi 1 ile gelir.
    expect(lostPresent, 0);
  });

  test('ilerleme paketi indekse yerine uygulanir', () {
    final tasks = [_task('a'), _task('b')];
    final index = _index(tasks);

    final batch = applyProgress(index, [
      _tick('a', downloaded: 400, speed: 2048),
      _tick('b', downloaded: 10, speed: 512),
    ], stale: false);

    expect(batch.lost, isFalse);
    expect(batch.changed, isTrue);
    expect(tasks[0].downloaded, 400);
    expect(tasks[0].speed, 2048);
    expect(tasks[1].downloaded, 10);
  });

  test('indekste olmayan kimlik yoksayilir', () {
    final tasks = [_task('a')];
    final index = _index(tasks);

    final batch = applyProgress(index, [_tick('yok')], stale: false);

    expect(batch.lost, isFalse);
    // Agac yeniden cizilmez: degisen bir sey yok.
    expect(batch.changed, isFalse);
    expect(tasks[0].downloaded, 0);
  });

  test('kayip bildirimi tasiyan paket hic uygulanmaz', () {
    final tasks = [_task('a')];
    final index = _index(tasks);

    // Ayni paket icinde gercek bir tik de olsa sonuc degismez: kayip
    // paketin yarisi gosterilmez, motorun listesi yeniden okunur.
    final batch = applyProgress(
      index,
      [_tick('a', downloaded: 999), _lost(42)],
      stale: false,
    );

    expect(batch.lost, isTrue);
    expect(batch.changed, isFalse);
    expect(tasks[0].downloaded, 0);
    // Kayip sayisi sadece iz icin tasinir; uygulamaya karismaz.
    expect(_lost(42).downloaded, 42);
  });

  test('esitleme beklerken paket bayat indekse uygulanmaz', () {
    final tasks = [_task('a')];
    final index = _index(tasks);

    final batch = applyProgress(
      index,
      [_tick('a', downloaded: 700)],
      stale: true,
    );

    // Kayit bildirimi degil, yalnizca toparlama sirasinda bekletildi.
    expect(batch.lost, isFalse);
    expect(batch.changed, isFalse);
    expect(tasks[0].downloaded, 0);
  });

  test('toparlama kuyrugu tek istegi birlestirir', () {
    final gate = ResyncGate();
    expect(gate.pending, isFalse);

    // Ilk kayit bildirimi ister; arka arkaya gelenler ayni toparlamaya
    // baglanir, yani bir dongu kurulamaz.
    expect(gate.onLost(), isTrue);
    expect(gate.pending, isTrue);
    expect(gate.onLost(), isFalse);
    expect(gate.onLost(), isFalse);
  });

  test('daha yeni tam liste bekleyen toparlamayi gereksiz kilar', () {
    final gate = ResyncGate();
    expect(gate.onLost(), isTrue);

    // Sorgudan once motorun tam listesi ulasti: o liste zaten dogrusu,
    // gereksiz bir sorgu yapilmaz.
    gate.onFullList();
    expect(gate.pending, isFalse);
  });

  test('toparlama bitince yeni bir kayit tekrar kabul edilir', () {
    final gate = ResyncGate();
    expect(gate.onLost(), isTrue);
    gate.onFullList();

    // Yeni bir tasma yeni bir toparlama demektir.
    expect(gate.onLost(), isTrue);
  });

  test('basarisiz toparlama sonraki denemeye izin verir', () {
    final gate = ResyncGate();
    expect(gate.onLost(), isTrue);

    // Motor okunamadi: kapi acilir ki sonraki kayit bildirimi yeniden
    // deneyebilsin.
    gate.cancel();
    expect(gate.pending, isFalse);
    expect(gate.onLost(), isTrue);
  });

  test('toparlama sonrasi onay bekleyen gorevler yeniden siraya girer', () {
    // Dusen onay olayinin karsiligi: gorev listede duruyor, kuyrukta yok.
    final gate = ResyncGate();
    final queue = HandoffQueue();
    expect(gate.onLost(), isTrue);

    final tasks = [_task('a', pending: true), _task('b')];
    for (final id in pendingHandoffIds(tasks)) {
      queue.request(id);
    }
    expect(queue.take(), 'a');

    // Sira motorun listesini yansitiyor: 'a' hala onay bekliyor, yani
    // toparlama onu dusurmuyor.
    expect(queue.sync(pendingHandoffIds(tasks)), isNull);
    gate.onFullList();
    expect(gate.pending, isFalse);
  });

  test('onay listesi yalnizca bekleyenleri kapsar', () {
    expect(
      pendingHandoffIds([
        _task('a'),
        _task('b', pending: true),
        _task('c', pending: true),
      ]),
      ['b', 'c'],
    );
    expect(pendingHandoffIds([_task('a')]), isEmpty);
  });
}
