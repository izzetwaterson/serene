# Serene

Windows için sakin ve düzenli bir indirme yöneticisi. Tauri 2 + Rust ile yazıldı;
arayüz `ui/` klasöründeki mockup'tan uyarlandı.

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

## Gereksinimler

- Rust (stable) + MinGW-w64 gcc
- WebView2 Runtime (Windows 10/11'de genelde kurulu gelir)
- Tarayıcı entegrasyonu için Firefox tabanlı bir tarayıcı (Zen Browser dahil)

## Geliştirme

Arayüz CSS'i Tailwind ile üretilir, ardından uygulama derlenir:

```cmd
cd src
..\tools\tailwindcss.exe -c tailwind.config.js -i input.css -o app.css --minify

cd ..\src-tauri
cargo run
```

`cargo run` hem `serene.exe` hem de `serene-nmh.exe` ikilisini derler. İki ikili de
gerekir: `serene-nmh.exe` tarayıcının native messaging köprüsüdür ve `serene.exe`'nin
yanında durmak zorundadır.

Derleme ve test:

```cmd
cd src-tauri
cargo build
cargo test
```

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
| Uygulama açıkken `serene.exe`'yi ikinci kez çalıştır | Yeni pencere açılmaz, var olan pencere öne gelir |
| "Kapatınca tepsiye gizle" açıkken Kapat düğmesi | Uygulama kapanmaz, tepsiye gizlenir; indirme sürer |
| Tarayıcıdan 256 KB'tan büyük bir dosya indir | Tarayıcının kendi indirmesi iptal olur, görev Serene'ye düşer ve bildirim çıkar |
| Bir bağlantıya sağ tıklayıp "Serene ile indir" | Görev oluşur; giriş gerektiren sitede de indirme çalışır (Referer/Cookie aktarılır) |
| HLS/DASH oynatan bir sayfada videoyu başlat | Eklenti rozeti artar, kayıt "Tarayıcıdan" panelinde görünür |
| Serene kapalıyken aynı sayfayı oynat | Rozet artar ama Serene kendiliğinden başlamaz |
| Panelden bir HLS yakalamasını indir | Tek `.ts` dosyası oluşur ve bir oynatıcıda açılır |
| Duraklat → uygulamayı kapat → yeniden aç → devam et | Tamamlanmış parçalar yeniden inmez, indirme kaldığı yerden sürer |

## Yayın derlemesi

```cmd
cd src-tauri
cargo build --release
```

`target\release\serene.exe` ve `target\release\serene-nmh.exe` birlikte kopyalanmalıdır.
NSIS kurulum paketi için:

```cmd
cargo tauri build
```

## Mimari

| Dosya | Sorumluluk |
|---|---|
| `src-tauri/src/models.rs` | Paylaşılan veri tipleri (görev, ayar, disk, yakalama) |
| `src-tauri/src/engine.rs` | İndirme motoru: probe, parça planı, akış, birleştirme |
| `src-tauri/src/manager.rs` | Kuyruk, eşzamanlılık, hız ölçümü, kalıcılık, olay yayını |
| `src-tauri/src/commands.rs` | Arayüzün çağırdığı Tauri komutları |
| `src-tauri/src/stream.rs` | Parça indirici/çözücü; HLS ve DASH bunu paylaşır |
| `src-tauri/src/hls.rs` | `m3u8` çözümleme, varyant seçimi, AES-128 anahtarları |
| `src-tauri/src/dash.rs` | `mpd` çözümleme (SegmentTemplate/List/Base, SegmentTimeline) |
| `src-tauri/src/bridge.rs` | Yerel TCP köprüsü: el sıkışma, komutlar, olay yayını |
| `src-tauri/src/native_host.rs` | Native messaging kaydı ve host manifesti |
| `src-tauri/src/bin/serene-nmh.rs` | Tarayıcı ile köprü arasında stdio aktarıcısı |
| `src-tauri/src/clipboard.rs` | Pano izleyici |
| `src-tauri/src/category.rs` | Uzantıdan kategori çıkarımı |
| `src-tauri/src/store.rs` | JSON durum dosyaları |
| `src/app.js` | Arayüz mantığı, olay abonelikleri |
| `src/index.html` | Arayüz iskeleti (Tailwind) |
| `extension/` | Firefox eklentisi: devralma, tarama, panel |

Arayüz ile çekirdek arasındaki sözleşme olaylar ve komutlardır:

- `tasks:update` — görev listesi değiştiğinde tam liste gönderilir
- `tasks:progress` — 400 ms'de bir yalnızca sayısal ilerleme gönderilir
- `clipboard:link` — panoda yeni bağlantı görüldüğünde
- `captures:update` — yakalanan medya listesi değiştiğinde tam liste gönderilir

İlerleme için ayrı olay kullanılmasının sebebi: saniyede birkaç kez tam liste
göndermek yerine sadece değişen sayıları yamamak, arayüzde gereksiz yeniden
çizimi önler.

Köprü protokolü satır sonuyla ayrılmış JSON'dur. Bağlanan istemci önce
`{"type":"hello","token":...}` gönderir, `ready` yanıtını alır ve `subscribe` ile
olaylara abone olur. Yanıtlar isteğin `reqId` alanını geri yansıtır.

## Bilinmeyenler / sınırlar

- Magnet/torrent bağlantıları reddedilir (kapsam dışı bırakıldı).
- Aynı anda aynı sunucudan çok sayıda bağlantı bazı sunucularda 429 ile
  karşılanabilir; `connections` ayarını düşürmek gerekir.
- Kategori klasörlere ayırma yapılmaz; kategori yalnızca arayüz filtresidir.
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
