# Serene

Windows için sakin ve düzenli bir indirme yöneticisi. Arayüz native Flutter
masaüstü uygulamasıdır (`flutter_app/`); indirme motoru Rust'ta yazılıdır
(`core/`) ve `flutter_rust_bridge` ile arayüzün içine gömülür, yani tek bir
çalıştırılabilir dosya vardır. Görsel tasarım `ui/` klasöründeki mockup'tan
uyarlandı.

Tauri + webview kabuğu (`src-tauri/` + `src/`) geçiş boyunca duruyor ve motorun
aynı çekirdeğini kullanıyor; Flutter kabuğu ona birebir eşdeğer görünümü hedefler.

## Ne yapar

- **Parçalı indirme** — `Range` istekleriyle tek dosyayı aynı anda 8 bağlantıdan çeker.
  Sunucu aralıkları desteklemiyorsa tek bağlantıya düşer.
- **Duraklat / devam ettir** — her parça kendi `.serene/<id>/partN` dosyasına yazılır,
  kaldığı yerden devam eder. Uygulama kapansa bile.
- **Kuyruk yönetimi** — eşzamanlı indirme sınırı ayarlanabilir; fazlası kuyrukta bekler.
- **Panodan yakalama** — kopyaladığınız bağlantıyı görüp önerir, kendi başına indirmez.
- **Kalıcılık** — görev listesi `%APPDATA%\Serene\tasks.json` dosyasında tutulur.
- **Kategoriler** — uzantıya göre Video / Ses / Belge / Yazılım / Arşiv / Görsel.
- **Tarayıcı eklentisi** — Firefox/Zen'de indirmeleri devralır, sayfada oynatılan HLS/DASH
  medyasını yakalar ve **Tarayıcıdan** panelinde öneri olarak listeler.
- **Akış indirme (HLS / DASH)** — `m3u8` ve `mpd` manifestleri parçalanıp indirilir,
  AES-128 şifreli HLS parçaları çözülür ve tek dosyada birleştirilir.
- **İstek başlığı aktarımı** — tarayıcıdaki `Referer`, `Cookie` ve `User-Agent` göreve
  taşınır; giriş/Referer doğrulayan CDN'lerden indirme çalışır.
- **İndirme onayı** — tarayıcıdan devralınan indirme, "İndirme Bilgileri" penceresi
  onaylanana kadar başlamaz. Boyut, kategori ve adres gösterilir; kayıt klasörü ile
  dosya adı burada değiştirilebilir. Medya yakalamaları ve elle girilen adresler
  bu pencereyi görmez.

## Gereksinimler

- Rust (stable) + MinGW-w64 gcc ya da Visual Studio Build Tools (C++)
- Flutter (masaüstü Windows desteğiyle) ve `flutter_rust_bridge_codegen` 2.13.0
- Yazı tiplerini yenilemek için Python + `fonttools`
- Eski Tauri kabuğu için WebView2 Runtime (Windows 10/11'de genelde kurulu gelir)
- Tarayıcı entegrasyonu için Firefox tabanlı bir tarayıcı (Zen Browser dahil)

## Geliştirme

### Flutter kabuğu (asıl arayüz)

Kurulum, çalıştırma ve derleme adımları `flutter_app/README.md` içinde. Özet:

```cmd
cd flutter_app
flutter pub get
flutter_rust_bridge_codegen generate
flutter run -d windows
```

`flutter build windows --debug` Rust motorunu cargokit ile birlikte derler ve
`build\windows\x64\runner\Debug\serene_app.exe` ikilisini üretir.

### Eski Tauri kabuğu

Arayüz CSS'i Tailwind ile üretilir, ardından uygulama derlenir:

```cmd
cd src
..\tools\tailwindcss.exe -c tailwind.config.js -i input.css -o app.css --minify

cd ..\src-tauri
cargo run
```

`cargo run` hem `serene.exe` hem de `serene-nmh.exe` ikilisini derler. İki ikili de
gerekir: `serene-nmh.exe` tarayıcının native messaging köprüsüdür ve uygulama
ikilisinin yanında durmak zorundadır.

Motor ve kabuklardan bağımsız Rust testleri:

```cmd
cd core
cargo test
```

### Doğrulama koşumları

`scripts/` altındaki koşumlar uygulamayı gerçekten başlatıp uçtan uca sınar. Hepsi
bir uygulama örneği açtığı ve aynı yerel köprüden komut verdiği için **sırayla**
koşulmalıdır; Flutter koşumları ayrıca ortada çalışan bir `serene_app.exe` görürse
kullanıcının uygulamasını öldürmemek için hiç başlamaz.

#### Flutter kabuğu

| Koşum | Doğruladığı |
|---|---|
| `node scripts/check_ffi.mjs` | Motor ikilisi exe'nin yanında; `--selfcheck` pencere açmadan kuruyor, komut gidip geliyor |
| `node scripts/check_flutter.mjs` | Gerçek uygulama: köprü, masaüstü penceresi, tek örnek, indirme, yakalama, **ayrı süreçteki onay penceresi**, kapanış |
| `cd flutter_app && flutter test` | Arayüz birim ve widget testleri: onay kuyruğu sırası, ayar paneli, bayt biçimlendirme |

Flutter'ın webview'i yok, üstelik Windows koşucusu `PostMessage` ile gönderilen
tıklamaları almıyor; bu yüzden arayüzü tarayıcı taklidiyle süren CDP koşumları
Flutter'a taşınmadı. `check_flutter.mjs` onun yerine uygulamayı başlatır, tarayıcı
eklentisinin kullandığı yerel köprüden komut verir ve pencereyi Win32'den okur
(`scripts/list_windows.ps1`).

#### Eski Tauri kabuğu

| Koşum | Doğruladığı | Webview'e bağımlı mı |
|---|---|---|
| `node scripts/check_bridge.mjs` | Yerel köprü: token, el sıkışma, komutlar, olay akışı | Kısmen (hazırlık + durum yoklaması) |
| `node scripts/check_hls.mjs` | HLS: varyant seçimi, birleştirme, AES-128, başlıklar, DRM reddi | Kısmen (durum + duraklat/devam) |
| `node scripts/check_dash.mjs` | DASH: SegmentTemplate/SegmentTimeline, video seçimi | Kısmen (durum yoklaması) |
| `node scripts/check_captures.mjs` | Yakalananlar: tekilleştirme, indirme, silme, kalıcılık | Kısmen (Tauri komutları) |
| `node scripts/check_panel.mjs` | "Tarayıcıdan" panelinin kendisi: rozet, kartlar, kaçış denetimi | Evet |
| `node scripts/check_tray.mjs` | Web kabuğunda tepsi, kapatınca gizleme, tek örnek | Evet |
| `node scripts/check_handoff.mjs` | Web arayüzündeki onay penceresi: sayfa içi modal | Evet |
| `node scripts/check_extension.mjs` | Eklenti mantığı, devralma, medya taraması, geri düşme | Hayır |
| `node scripts/check_nmh.mjs` | Native messaging kaydı, çerçeveleme, sessiz başlatma | Hayır |

Son iki satır arayüzden bağımsızdır: `serene-nmh.exe` uygulama ikilisinin yanında
durdukça Flutter derlemesiyle de çalışır, çünkü sessiz başlatma hem `serene.exe`
hem `serene_app.exe` adını çözer. "Kısmen" satırları motorun kendi doğrulamasını
köprü üzerinden yapar, yalnızca hazırlık ve durum okuma için webview'e danışır;
bunlar köprüye devredilmeden `src/` emekli edilemez.

Üç koşum kullanıcı durumuna dokunur; hepsi önce yedekler, sonunda geri koyar:

- `check_nmh.mjs` kayıt defteri anahtarını siler; kaydı geri kurmak için o
  derlemenin `serene.exe --register-host` komutu çalıştırılır.
- `check_handoff.mjs` `tasks.json`'u yedekleyip boşaltır ve
  `confirmBrowserDownload` ayarını kendi ihtiyacına göre açıp kapatır.
- `check_extension.mjs` `settings.json`'da `confirmBrowserDownload` ayarını geçici
  olarak kapatır (devralma adımı onay penceresinde takılmasın diye).

`check_ffi.mjs` ve `check_flutter.mjs` bunları yapmaz: motoru `SERENE_DATA_DIR`
ile geçici bir klasöre yönlendirir, indirmeleri de oraya açtıkları alt klasöre
yapar. Kalan koşumlar kullanıcının gerçek `%APPDATA%\Serene` ve `İndirilenler`
durumunu kullandığı için çalıştırırken tarayıcı kapalı olmalıdır.

Tauri koşumları varsayılan olarak `target\debug` ikililerini kullanır. Başka bir
derlemeyi denemek için `SERENE_EXE` (uygulama ikilisi) ve `SERENE_TARGET_DIR`
(iki ikilinin klasörü) verilir:

```cmd
set SERENE_EXE=%CD%\src-tauri\target\release\serene.exe
set SERENE_TARGET_DIR=%CD%\src-tauri\target\release
node scripts\check_bridge.mjs
```

Flutter koşumları `flutter_app\build\windows\x64\runner\Debug\serene_app.exe`
ikilisini kullanır; yolu değiştirmek için `SERENE_APP_EXE` verilir.

```cmd
set SERENE_APP_EXE=%CD%\flutter_app\build\windows\x64\runner\Release\serene_app.exe
node scripts\check_flutter.mjs
```

> Uygulama her açılışta native messaging kaydını yanındaki `serene-nmh.exe`'ye
> çevirir. Release Flutter klasöründe o ikili varsa kayıt da oraya döner;
> kaydı geri almak için Tauri derlemesini bir kez `--register-host` ile
> çalıştırın.

`smoke_test.py`, `e2e_download.py` (klavye girdisi gönderir, pencere odağı ister) ve
`e2e_cdp.mjs` (dış ağdan indirme) yardımcı koşumlardır; günlük doğrulama için yukarıdaki
liste yeterlidir.

## Tarayıcı eklentisi

Eklenti `extension/` klasöründedir (Firefox Manifest V2, kalıcı arka plan betiği).
Zen Browser bir Firefox çatalı olduğu için aynı adımlar geçerlidir.

### Kurulum

1. Native messaging kaydını kurun. Normal başlatmada zaten otomatik tazelenir; elle
   kurmak veya yolu tazelemek için:
   ```cmd
   src-tauri\target\debug\serene.exe --register-host
   ```
   Bu komut iki şey yapar:
   - `%APPDATA%\Serene\nmh\com.serene.nmh.json` host manifestini yazar
   - `HKCU\Software\Mozilla\NativeMessagingHosts\com.serene.nmh` kayıt defteri
     anahtarını manifestin yoluna işaret ettirir

   Kaldırmak için `--unregister-host`. Sorun giderme günlüğü:
   `%APPDATA%\Serene\nmh\register.log`.

2. Tarayıcıda `about:debugging#/runtime/this-firefox` adresini açın, **Geçici Eklenti
   Yükle** ile `extension/manifest.json` dosyasını seçin.

3. Eklenti simgesine tıklayın; açılan pencerede durum **bağlı** görünmelidir. Serene
   çalışmıyorsa **Serene kapalı** yazar.

> Geçici eklentiler tarayıcı kapanınca düşer; tarayıcıyı yeniden açtığınızda 2. adımı
> tekrarlamanız gerekir. Kalıcı kurulum imzalı bir `.xpi` paketi gerektirir ve bu
> deponun kapsamı dışındadır.

### Nasıl çalışır

Eklenti her şeyi `browser.runtime.connectNative` üzerinden yapar; uygulamaya giden yol
iki atlamalıdır:

- **Native messaging** — tarayıcı `serene-nmh.exe` sürecini başlatır ve stdin/stdout
  üzerinden 4 baytlık uzunluk önekli JSON konuşur. Bu ikili Tauri'yi linklemediği için
  küçüktür ve hızlı açılır.
- **Yerel köprü (loopback)** — uygulama `127.0.0.1` üzerinde rastgele bir portta TCP
  dinler; port ve rastgele token `%APPDATA%\Serene\ipc.json` dosyasına yazılır.
  `serene-nmh.exe` native messaging'den gelen mesajları bu köprüye aktarır. Köprü
  token'ı doğrular; böylece makinedeki başka bir süreç uygulamaya komut veremez.

Bağlantı tembeldir: eklenti `serene-nmh.exe` sürecini yalnızca gerçekten gerektiğinde
(devralma, panel, medya indirme) başlatır. **Medya taraması pasiftir** — uygulama
kapalıysa ayağa kaldırılmaz; yakalananlar yalnızca açık bir köprü varsa arayüze düşer.

Medya taraması yanıt başlıklarını gözlemleyerek çalışır: sekme başına HLS/DASH adayları
toplanır, simgeye rozet basılır ve liste tarayıcı oturumunda tutulur (sekme kapanınca
temizlenir). Küçük ilerlemeli medya yanıtları ve `Range` istekleri elenir; böylece aynı
dosya onlarca kez öneri olarak birikmez.

## Elle doğrulama

Otomatik testlerin kapsamadığı, tarayıcı ve masaüstü davranışına bağlı adımlar:

| Deneme | Beklenen |
|---|---|
| Uygulama açıkken ikilisi bir daha çalıştır | Yeni pencere açılmaz, var olan pencere öne gelir |
| "Kapatınca tepsiye gizle" açıkken Kapat düğmesi | Uygulama kapanmaz, tepsiye gizlenir; indirme sürer |
| Tarayıcıdan 256 KB'tan büyük bir dosya indir | Tarayıcının kendi indirmesi iptal olur; "İndirme Bilgileri" penceresi açılır ve indirme onaylanana kadar başlamaz |
| Pencerede klasörü ve dosya adını değiştirip "İndirmeyi Başlat" | İndirme yeni konuma, yeni adla iner; görev kartı da yeni adı gösterir |
| Pencerede "Daha Sonra" | Görev "Onay bekliyor" durumunda listede kalır; karttaki bilgi düğmesi pencereyi geri getirir |
| Bir bağlantıya sağ tıklayıp "Serene ile indir" | Görev oluşur; giriş gerektiren sitede de indirme çalışır (Referer/Cookie aktarılır) |
| HLS/DASH oynatan bir sayfada videoyu başlat | Eklenti rozeti artar, kayıt "Tarayıcıdan" panelinde görünür |
| Serene kapalıyken aynı sayfayı oynat | Rozet artar ama Serene kendiliğinden başlamaz |
| Panelden bir HLS yakalamasını indir | Tek `.ts` dosyası oluşur ve bir oynatıcıda açılır |
| Duraklat → uygulamayı kapat → yeniden aç → devam et | Tamamlanmış parçalar yeniden inmez, indirme kaldığı yerden sürer |

## Yayın derlemesi

### Flutter

```cmd
node scripts\deploy_flutter.mjs
```

Betik üç işi sırayla yapar: `flutter build windows --release` (Rust motorunu
cargokit ile birlikte derler), `serene-nmh.exe` hedefini ayrı olarak derler ve
yayın klasörüne kopyalar, sonra klasörün içeriğini raporlar. Tarayıcı
entegrasyonu için host ikilisinin uygulama ikilisinin yanında durması şarttır;
bu kopyalama yapılmazsa Flutter sürümünde pencere açılır ve indirme çalışır ama
tarayıcıdan hiçbir devralma gelmez.

Ayrıca:

- `--debug` Debug klasörünü hedefler, `--no-build` hazır derlemeleri kopyalar.
- `--register` tarayıcının native messaging kaydını bu klasöre çevirir. Yazmadan
  önce manifesti ve kayıt defteri anahtarını geçici bir klasöre yedekler; o
  klasörle `node scripts\deploy_flutter.mjs --restore <yedek>` geri alınır.
  Kayıt kullanıcı durumuna dokunduğu için betiğin varsayılanı kayda dokunmaz.

Klasörü taşırken `serene_app.exe`, `rust_lib_serene.dll`, `flutter_windows.dll`,
ek plugin dll'leri, `data\` ve `serene-nmh.exe` birlikte gitmelidir.

### Eski Tauri kabuğu

```cmd
cd src-tauri
cargo build --release
```

`target\release\serene.exe` ve `target\release\serene-nmh.exe` birlikte kopyalanmalıdır;
`serene-nmh.exe` her zaman `serene.exe`'nin yanında aranır. Tauri aynı klasöre
`WebView2Loader.dll` de bırakır — klasörü olduğu gibi taşımak en güvenlisi. NSIS kurulum
paketi için:

```cmd
cargo tauri build
```

Native messaging kaydı **son çalıştırılan derlemeyi** işaret eder: uygulama her açılışta
kendi klasöründeki `serene-nmh.exe` yolunu yazar. Yayın klasörünü başka bir yere
taşıdıysanız oradaki ikiliyi bir kez çalıştırmak kaydı tazeler; araya giren bir
geliştirme derlemesi kaydı tekrar `target\debug`'a çevirir. `SERENE_DATA_DIR`
verilmişse (koşumların yalıtılmış çalıştırması) Flutter kabuğu kayda hiç
dokunmaz: o kipte köprü geçici klasörde doğar, tarayıcı ise gerçek klasöre bakar.

## Mimari

### Motor — `core/` (`serene-core`, kabuklardan bağımsız)

| Dosya | Sorumluluk |
|---|---|
| `core/src/models.rs` | Paylaşılan veri tipleri (görev, ayar, disk, yakalama) |
| `core/src/runtime.rs` | Motorun kendi tokio zamanlayıcısı; `tokio::spawn` değil `runtime::spawn` kullanılır |
| `core/src/bus.rs` | `EventBus` ve `CoreEvent` yayını |
| `core/src/engine.rs` | İndirme motoru: probe, parça planı, akış, birleştirme |
| `core/src/manager.rs` | Kuyruk, eşzamanlılık, hız ölçümü, kalıcılık, olay yayını |
| `core/src/stream.rs` | Parça indirici/çözücü; HLS ve DASH bunu paylaşır |
| `core/src/hls.rs` | `m3u8` çözümleme, varyant seçimi, AES-128 anahtarları |
| `core/src/dash.rs` | `mpd` çözümleme (SegmentTemplate/List/Base, SegmentTimeline) |
| `core/src/enqueue.rs` | Adresten görev üretme, istek başlıkları, onay bekleme kararı |
| `core/src/bridge.rs` | Yerel TCP köprüsü: el sıkışma, komutlar, olay yayını |
| `core/src/clipboard.rs` | Pano izleyici |
| `core/src/category.rs` | Uzantıdan kategori çıkarımı |
| `core/src/store.rs` | JSON durum dosyaları ve `SERENE_DATA_DIR` yalıtımı |

### Tarayıcı köprüsü

| Dosya | Sorumluluk |
|---|---|
| `native-host/src/lib.rs` | Native messaging kaydı ve host manifesti (motoru linklemez) |
| `src-tauri/src/bin/serene-nmh.rs` | Tarayıcı ile köprü arasında stdio aktarıcısı, sessiz başlatma |
| `extension/` | Firefox eklentisi: devralma, tarama, panel |

### Flutter kabuğu — asıl arayüz

| Dosya | Sorumluluk |
|---|---|
| `flutter_app/rust/src/api/` | Dart'a açılan komut, olay ve tip katmanı (flutter_rust_bridge) |
| `flutter_app/rust/src/state.rs` | Tek motor örneği; ayağa kaldırmayı yalnızca ana pencere yapar |
| `flutter_app/lib/src/main_window.dart` | Ana pencere, olay abonelikleri, tepsi, tek örnek, onay kuyruğu |
| `flutter_app/lib/src/cards.dart` | Görev listesi, kartlar, "Tarayıcıdan" paneli |
| `flutter_app/lib/src/settings_view.dart` | Ayarlar katmanı |
| `flutter_app/lib/src/handoff_window.dart` | Ayrı süreçteki "İndirme Bilgileri" penceresi |
| `flutter_app/lib/src/handoff.dart` | Onay sırası — saf Dart, birim testli |
| `flutter_app/lib/src/folder_picker.dart` | Yerel klasör seçme diyaloğunun tek kapısı |
| `flutter_app/lib/src/theme.dart` | Renk ve tipografi belirteçleri |

### Eski Tauri kabuğu

| Dosya | Sorumluluk |
|---|---|
| `src-tauri/src/commands.rs` | Arayüzün çağırdığı Tauri komutları |
| `src-tauri/src/tray.rs` | Tauri tepsi menüsü |
| `src/app.js`, `src/index.html` | Web arayüzü; Flutter için görsel referans |

## Olay ve komut sözleşmesi

Motor kararlarını `EventBus` üzerinden `CoreEvent` olarak yayınlar; her kabuk
aynı kutuya abone olur:

| Çekirdek olayı | Anlamı |
|---|---|
| `Tasks(liste)` | Görev listesi değişti, tam liste gönderilir |
| `Progress(tikler)` | 400 ms'de bir yalnızca sayısal ilerleme |
| `Captures(liste)` | Yakalanan medya listesi değişti |
| `HandoffPending(görev)` | Tarayıcı devralması onay bekliyor |
| `ClipboardLink(bağlantı)` | Panoda yeni bağlantı görüldü |
| `PresentWindow` | Pencere öne getirilsin |

İlerleme için ayrı olay kullanılmasının sebebi: saniyede birkaç kez tam liste
göndermek yerine sadece değişen sayıları yamamak, arayüzde gereksiz yeniden
çizimi önler.

Flutter bu olayları `watchTasks/Progress/Captures/Handoff/Clipboard/Present`
akışları olarak alır ve komutları doğrudan FFI'dan çağırır — arada soket yoktur.
Tauri kabuğu aynı kutuyu eski adlarla (`tasks:update` vb.) webview'e çevirir.

Tarayıcı ve başka süreçler için ayrı bir kanal vardır: köprü protokolü satır
sonuyla ayrılmış JSON'dur. Bağlanan istemci önce `{"type":"hello","token":...}`
gönderir, `ready` yanıtını alır ve `subscribe` ile olaylara abone olur. Yanıtlar
isteğin `reqId` alanını geri yansıtır. Onay penceresi de aynı kanalı kullanır:
ikinci süreç kendi motorunu kurmaz, kararı çalışan örneğe yazar.

## Flutter geçişinin durumu

Arayüz native Flutter'a taşındı ve motorunun içine gömüldü. Tamamlanan adımlar:

- Gomulu motor: `flutter_app/rust` ayrık derleme olmadan cargokit ile kurulur,
  komutlar ve olaylar FFI üzerinden gider; arayüz ile çekirdek arasında soket yok.
- Arayüz: görev listesi, kartlar, "Tarayıcıdan" paneli, arama ve filtreler,
  ilerleme çubukları `src/` görünümüyle birebir aynı.
- Kabuk davranışı: tepsi simgesi, kapatınca tepsiye gizleme, tek örnek koruması.
- "İndirme Bilgileri" onayı: ayrı bir işletim sistemi penceresi olarak, ikinci bir
  süreçte açılır ve kararını köprü üzerinden çalışan örneğe yazar.
- Ayarlar penceresi, yerel klasör seçme diyaloğu ve ayar değişince yenilenen disk
  kullanımı.
- Doğrulama: `check_ffi.mjs`, `check_flutter.mjs` ve `flutter test`.

`src/` ve `src-tauri/` bilinçli olarak duruyor; emeklilik ayrı bir karar. Kararın
önündeki engeller:

- Yukarıdaki tabloda "Evet" ve "Kısmen" satırlarında işaretlenen koşumlar webview'e
  danışıyor. Bunlar köprüye ya da Flutter testlerine devredilmeden eski kabuk
  silinemez.
- `serene-nmh.exe` hâlâ `src-tauri` paketinin bir hedefi. Kodu Tauri'den bağımsız
  (`native-host/` kutuphanesini linkler) ama ikiliyi üretmek için o pakette
  `cargo build` gerekiyor; `deploy_flutter.mjs` oradan kopyalıyor. Emeklilikten
  önce host'un `native-host/` paketine taşınması gerekir.
- Native messaging kaydı tek bir uygulamayı işaret eder; iki kabuk yan yana
  dururken son açılan kazanır. Bu yüzden `deploy_flutter.mjs` kaydı varsayılan
  olarak çevirmez ve `--register` açıkça istenir.
- Kurulum paketi (NSIS) yalnızca Tauri tarafında tanımlı; Flutter için henüz bir
  yükleyici yok, yayın klasörü elle taşınıyor.

## Bilinmeyenler / sınırlar

- Magnet/torrent bağlantıları reddedilir (kapsam dışı bırakıldı).
- Aynı anda aynı sunucudan çok sayıda bağlantı bazı sunucularda 429 ile
  karşılanabilir; `connections` ayarını düşürmek gerekir.
- Kategori klasörlere ayırma yapılmaz; kategori yalnızca arayüz filtresidir.
  "İndirme Bilgileri" penceresindeki kategori de salt okunur bir etikettir: dosya
  adından türetilir ve seçilen klasörü değiştirmez.
- **DRM reddedilir.** `SAMPLE-AES` gibi şifreli akışlar için görev, ne olduğunu
  söyleyen bir hatayla başarısız olur; çözmenin bir yolu yoktur.
- **MSE / blob akışları yakalanamaz.** Medyayı JavaScript ile `blob:` adresine yazan
  oynatıcılarda indirilebilir bir akış adresi bulunmaz.
- **Akışta toplam boyut ancak bitince bilinir.** HLS/DASH manifestleri toplam bayt
  söylemez; ilerleme çubuğu parça sayısı üzerinden yürür ve boyut "bilinmiyor"
  görünür.
- **Ayrı ses kanalı birleştirilmez.** DASH manifestinde video ve ses ayrıysa yalnızca
  video indirilir; iki parçayı tek dosyada birleştirmek (muxing) yapılmaz.
- **Parça içinde aralıklı devam yoktur.** Duraklatıp devam ederken tamamlanmış
  parçalar yeniden inmez, ama yarım kalan parça baştan indirilir.
