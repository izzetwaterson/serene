import 'package:flutter_test/flutter_test.dart';

import 'package:serene_app/src/data.dart';
import 'package:serene_app/src/format.dart';
import 'package:serene_app/src/strings.dart';

Task _task({
  String status = 'downloading',
  bool pending = false,
  int total = 1048576,
  int downloaded = 524288,
  double speed = 0,
  int? finishedAt,
  String? error,
}) => Task(
      id: 'a',
      url: 'https://ornek/x.mp4',
      filename: 'x.mp4',
      dest: r'C:\indir\x.mp4',
      total: total,
      downloaded: downloaded,
      speed: speed,
      status: status,
      category: 'video',
      createdAt: 0,
      finishedAt: finishedAt,
      error: error,
      pending: pending,
    );

void main() {
  // Metinler globaldir; bir testin biraktigi dil digerine sizmasin.
  tearDown(() => applyLanguage(AppLanguage.tr));

  test('dil ayari taninan degerlere iner', () {
    expect(languageSetting(languageFrom(' EN ')), 'en');
    expect(languageSetting(languageFrom('Tr')), 'tr');
    // Eski ayar dosyalarinda alan yok; elle duzenlenen deger de varsayilana
    // duser, cunku motordaki `normalize_language` ayni kumeyi tanir. Varsayilan
    // Ingilizcedir.
    expect(languageSetting(languageFrom('')), 'en');
    expect(languageSetting(languageFrom('de')), 'en');
  });

  test('dil degisince dinleyiciler haberdar olur', () {
    var calls = 0;
    void listener() => calls++;
    appLanguage.addListener(listener);
    addTearDown(() => appLanguage.removeListener(listener));

    applyLanguage(AppLanguage.en);
    expect(appLanguage.value, AppLanguage.en);
    expect(calls, 1);

    // Ayni dil yeniden yazilinca bosuna bildirim olmaz: `ValueNotifier`
    // esit degerde susar ve pencere gereksiz kurulmaz.
    applyLanguageSetting('en');
    expect(calls, 1);

    applyLanguageSetting('tr');
    expect(calls, 2);
  });

  test('iki dil ayni alanlari doldurur', () {
    // Derleyici eksik alani zaten yakalar; burada metinlerin gercekten
    // degistigi ve varsayilanin Turkce kaldigi dogrulanir.
    expect(T.heroTitle, 'Bugün ne indirmek istersiniz?');
    expect(T.unknownAction('zap'), '"zap" islemi taninmiyor');

    applyLanguage(AppLanguage.en);
    expect(T.heroTitle, 'What would you like to download today?');
    expect(T.unknownAction('zap'), 'Unknown action "zap"');
    expect(T.bytesWord, 'bytes');
    expect(T.thousandSeparator, ',');
  });

  test('sure bicimi dile gore birim kullanir', () {
    expect(fmtEta(45), '45 sn');
    expect(fmtEta(90), '1 dk 30 sn');
    expect(fmtEta(3700), '1 sa 1 dk');

    applyLanguage(AppLanguage.en);
    expect(fmtEta(45), '45 s');
    expect(fmtEta(90), '1 m 30 s');
    expect(fmtEta(3700), '1 h 1 m');
  });

  test('tarih satiri dile gore ay ve kalibi kullanir', () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 9, 5);
    final todaySecs = today.millisecondsSinceEpoch ~/ 1000;
    final oldSecs =
        DateTime(2020, 3, 4, 7, 8).millisecondsSinceEpoch ~/ 1000;

    expect(fmtWhen(todaySecs), 'Bugün, 09:05');
    expect(fmtWhen(oldSecs), '4 Mar 2020, 07:08');

    applyLanguage(AppLanguage.en);
    expect(fmtWhen(todaySecs), 'Today, 09:05');
    expect(fmtWhen(oldSecs), 'Mar 4, 2020, 07:08');
  });

  test('gorev satiri dili izler', () {
    // Kalan sure hesabi icin hiz gerekir: (1 MiB - 512 KiB) / 30 sn.
    final task = _task(speed: (1048576 - 524288) / 30);
    expect(metaLine(task), contains('Kalan süre: 30 sn'));
    expect(metaLine(_task(total: 0)), contains('Boyut bilinmiyor'));

    applyLanguage(AppLanguage.en);
    expect(metaLine(task), contains('Time left: 30 s'));
    expect(metaLine(_task(total: 0)), contains('Size unknown'));
  });

  test('durum rozeti ve eylem etiketleri dili izler', () {
    expect(statusChip(_task(status: 'paused')).label, 'Duraklatıldı');
    expect(
      actionsFor(_task(status: 'completed')).map((action) => action.title),
      ['Dosyayı Aç', 'Klasörde Göster', 'Kaldır'],
    );

    applyLanguage(AppLanguage.en);
    expect(statusChip(_task(pending: true)).label, 'Awaiting confirmation');
    expect(statusChip(_task(status: 'failed')).label, 'Error');
    expect(
      actionsFor(_task(status: 'paused', pending: true))
          .map((action) => action.title),
      ['Open Details', 'Resume', 'Cancel'],
    );
  });

  test('filtre ve kategori basliklari dili izler', () {
    expect(filterTitles['all'], 'Tüm İndirmeler');
    expect(categoryTitles['image'], 'Görseller');

    applyLanguage(AppLanguage.en);
    expect(filterTitles['all'], 'All Downloads');
    expect(categoryTitles['image'], 'Images');
  });

  test('yakalama etiketleri dili izler', () {
    expect(captureKindLabel('file'), 'Dosya');
    expect(captureKindLabel('hls'), 'HLS');

    applyLanguage(AppLanguage.en);
    expect(captureKindLabel('file'), 'File');
    expect(captureKindLabel('dash'), 'DASH');
  });
}
