# Serene — Flutter kabuğu

Depodaki **asıl arayüz**. İndirme motoru (`core/`) `flutter_rust_bridge` ile bu
projenin içine gömülür: ortaya tek `Serene.exe` ve yanındaki
`rust_lib_serene.dll` çıkar, arayüz ile motor arasında soket ya da protokol
yoktur.

Görsel hedef `ui/` klasöründeki mockup'tır.

## Gereksinimler

- Flutter (masaüstü Windows desteğiyle) ve `flutter config --enable-windows-desktop`
- Rust (stable) + Visual Studio Build Tools (C++ iş yükü)
- `cargo install flutter_rust_bridge_codegen --version 2.13.0`

## Kurulum

```cmd
flutter pub get

:: Rust->Dart baglantilarini yeniler (lib/src/rust/)
flutter_rust_bridge_codegen generate
```

Codegen yalnızca `rust/src/api/` altındaki public API'yi görür; Dart'a
görünecek her yeni komut ya da olay akışı oraya yazılır ve ardından yeniden
üretilir.

## Çalıştırma, test, derleme

```cmd
flutter run -d windows
flutter analyze && flutter test
flutter build windows --debug      :: build\windows\x64\runner\Debug\Serene.exe
flutter build windows --release    :: ...\Release\Serene.exe
```

`flutter build windows` Rust'ı cargokit üzerinden kendisi derler; ayrı bir
`cargo build` gerekmez.

## Yayın klasörü

Derlenmiş klasör tek başına tarayıcıyla konuşamaz: eklenti uygulamaya
`serene-nmh.exe` üzerinden ulaşır ve o ikili her zaman `Serene.exe`'nin
yanında aranır. İkisini bir araya getiren adım:

```cmd
node ..\scripts\deploy_flutter.mjs            :: Release derle + host'u kopyala
node ..\scripts\deploy_flutter.mjs --debug    :: Debug klasoru
node ..\scripts\deploy_flutter.mjs --register :: bir de tarayici kaydini cevir
```

Uygulama her açılışta kaydı kendi klasörüne çevirdiği için `--register`
varsayılan değildir; betik yazmadan önce yedek alır ve `--restore <yedek>` ile
geri alınır. `SERENE_DATA_DIR` verilmişse (koşumların yalıtılmış çalıştırması)
kayda hiç dokunulmaz.

## Açılış kipleri

Aynı ikili birkaç farklı pencereyle açılabilir; koşumlar ve elle deneme bu
bayrakları kullanır:

| Komut | Sonuç |
|---|---|
| `Serene.exe` | Ana pencere; motor bu süreçte kurulur |
| `Serene.exe --demo` | Ana pencere örnek görevlerle (motor listesi boşa çıkmaz) |
| `Serene.exe --settings` | Ana pencere, ayarlar katmanı açık |
| `Serene.exe --handoff=<base64url>` | "İndirme Bilgileri" onayı, **ayrı süreçte** pencere |
| `Serene.exe --handoff-demo` | Aynı pencere örnek görevle; motora komut göndermez |
| `Serene.exe --selfcheck` | Pencere açmadan köprü yoklaması; `KOPRU ...` satırı yazar |

`SERENE_DATA_DIR` verilirse motor tüm durum dosyalarını (`tasks.json`,
`settings.json`, `captures.json`, `ipc.json`) oraya yazar. `--selfcheck` bu
değişken olmadan 2 ile çıkar; koşumlar da yalıtılmış bir geçici klasörle
çalışır, böylece kullanıcının `%APPDATA%\Serene`'ine dokunulmaz.

Onay penceresi ana pencerenin `Process.start` ile açtığı ikinci bir örnektir:
Flutter çok pencereli olmadığı için ayrı süreç gerekir, ve ikinci süreç
`bootEngine` çağırmayıp kararı `ipc.json` üzerinden çalışan örneğe yollar —
aksi halde iki motor aynı görev listesine yazardı.

## Bilinen tuzaklar

- **Olay havuzu tokio değildir.** FRB kendi basit iş parçacığı havuzunu kurar;
  ağ işi yapan komutlar `serene_core::runtime::spawn(...)` ile motorun kendi
  runtime'ına taşınır. Doğrudan `tokio::spawn` "there is no reactor running"
  ile çöker.
- **`StreamSink` kök modülden dışa aktarılmaz:** `use crate::frb_generated::StreamSink;`
  gerekir ve `sink.add(..)` dinleyici ayrılınca hata döndürür.
- **Kopya tipler zorunlu.** Çekirdek tipleri `api/dto.rs` içinde elle çevrilir:
  FRB codec impl'leri yetim kuralına takılır, ayrıca `u64` Dart'ta `BigInt`'e
  karşılık geldiği için bayt alanları `i64`'e indirgenir.
- **`flutter_app/rust` crate'ine `serde_json` eklenmez.** JSON kuralları
  çekirdekte (`core/src/bridge.rs`) durur; eklenirse FRB derlemesi bozulur.
- **Windows koşucusu pencereyi Dart `main()` dönmeden açar.** Erken çıkmak
  isteyen kipler `return` yerine `exit(0)` kullanmalı, aksi halde ekranda boş
  bir pencere kalır.
- **Flutter, PostMessage ile gönderilen tıklamaları almaz.** Bu yüzden arayüz
  CDP/sentetik tık ile koşulandırılamaz; davranış `flutter test` ile,
  kabuk-motor bütünleşmesi `node scripts/check_flutter.mjs` ile doğrulanır.
- **Yazı tipi testi.** `test/font_test.dart` olmadan ikonlar sessizce yedek yazı
  tipine düşer. Yazı tipleri `assets/fonts/` altında TTF olarak depoda durur:
  değişken eksenler statik değere sabitlenmiş, sfnt başlığı doğrulanmıştır.

## Doğrulama

```cmd
flutter analyze
flutter test
cd .. && node scripts\check_ffi.mjs       :: kopru + dll + --selfcheck
node scripts\check_flutter.mjs            :: pencere, tek ornek, indirme, onay akisi
```

`check_flutter.mjs` uygulamayı gerçekten başlatır, tarayıcının kullandığı yerel
köprüden komut verir ve işletim sistemi penceresini Win32'den okur
(`scripts/list_windows.ps1`). Ekran görüntüsü için, pencereyi öne alıp yalnızca
onu yakalayan yardımcı:

```cmd
powershell -NoProfile -File scripts\capture_window.ps1 -ProcessName Serene
```
