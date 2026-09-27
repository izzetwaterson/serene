<div align="center">
  <img src="ui/serene-icon.png" width="96" alt="Serene">
  <h3>Serene</h3>
  <p><b>Sakin ve düzenli bir Windows indirme yöneticisi.</b></p>
  <p>Türkçe · <a href="#english">English</a></p>
</div>

---

Windows için tasarlanmış bir indirme yöneticisi. Hızlı olmaya çalışmaz;
**sakin** olmaya çalışır: tek ekranda, sırasız, kesintisiz.

- **Parçalı indirme** — `Range` istekleriyle tek dosyayı aynı anda 8 bağlantıdan çeker. Sunucu aralıkları desteklemiyorsa tek bağlantıya düşer.
- **Kaldığı yerden devam** — her parça kendi dosyasına yazılır; uygulama kapansa bile kaldığınız yerden sürer.
- **Akış indirme** — `m3u8` (HLS) ve `mpd` (DASH) manifestleri parçalanıp indirilir, AES-128 şifreli parçalar çözülür, tek dosyada birleştirilir.
- **Tarayıcıdan devralma** — Firefox/Zen'de bir indirme başlatsanız Serene üstüne alır. Sitenin `Referer`/`Cookie`/`User-Agent` başlıkları da taşınır, yani giriş isteyen CDN'lerde de çalışır.
- **Medya yakalama** — sayfada oynatılan HLS/DASH medyası yakalanır, **Tarayıcıdan** panelinde öneri olur.
- **Onaylı devralma** — tarayıcıdan gelen indirme "İndirme Bilgileri" penceresinde onaylanana kadar başlamaz. Klasör ve dosya adı orada değiştirilebilir.
- **Pano yakalama** — kopyaladığınız bağlantıyı görüp önerir; kendi başına indirmez.
- **Kuyruk ve kategoriler** — eşzamanlılık sınırı ayarlanabilir, fazlası bekler. Kategoriler uzantıya göre otomatik.
- **Karanlık / aydınlık**, **Türkçe / İngilizce**.

> **Kod imzalama yok.** Windows SmartScreen kurulumda "bilinmeyen yayıcı" uyarısı
> verebilir. Bu bilinçli bir seçimdir; kaldırmak için kurulumu normal kullanıcı
> olarak çalıştırmanız yeterli.

---

## Kurulum

**Serene-Setup-1.0.0.exe** dosyasını çalıştırın. Yönetici şifresi **sorulmaz**.

Kurulum sırasında seçebilecekleriniz:

| Seçenek | Varsayılan |
|---|---|
| Kurulum klasörü | `%LOCALAPPDATA%\Programs\Serene` |
| Başlat menüsü kısayolu | açık |
| Windows açılışında başlat | **kapalı** |
| Tarayıcı köprüsü kaydı | açık (Firefox/Zen gerekir) |

Kaldırma: `Başlat → Ayarlar → Uygulamalar → Serene`. Kaldırma sırasında
`%APPDATA%\Serene` klasöründeki **görev listeniz korunur**.

### Tarayıcı eklentisi (isteğe bağlı)

Kurulum tarayıcı köprüsünü kaydeder. Eklentinin kendisi imzasız olduğu için
Firefox'un mağazasından gelmez; elle yüklenir:

1. Firefox veya Zen'de `about:debugging#/runtime/this-firefox` adresini açın
2. **Geçici Eklenti Yükle** → `extension/manifest.json` dosyasını seçin
3. Eklenti simgesine tıklayın; durum **bağlı** görünmelidir

> Geçici eklentiler tarayıcı kapanınca düşer, bir sonraki açılışta 2. adımı
> tekrarlamanız gerekir. Kalıcı kurulum imzalı bir `.xpi` gerektirir.

---

## Gereksinimler

- **Windows 10 veya 11** (x64)
- Firefox veya Zen — yalnızca tarayıcı entegrasyonu için
- Diskte ~40 MB kurulum + indirmeler

İnternet gereksinimi yoktur; Serene tamamen yerel çalışır.

---

## Ekran görüntüleri

<details open>
<summary><b>Ana pencere (karanlık tema)</b></summary>

![Ana pencere](artifacts/serene-ekran.png)

*Kuyruk sayaçları, kategori filtresi, ilerleme çubukları ve disk kullanımı
sol sütunda; sağda o anki indirmeler.*
</details>

<details>
<summary><b>Aydınlık tema ve ayarlar</b></summary>

Ayar katmanı ana pencerenin üzerinde açılır: tema (Sistem / Aydınlık /
Karanlık), dil (Türkçe / İngilizce), pano izleme, tepsiye gizleme, tarayıcı
indirmelerini sorma, Windows açılışında başlatma, bağlantı sayısı ve eşzamanlı
indirme limiti.

Görüntüler `artifacts/` altındadır; `scripts/capture_window.ps1` ile yeniden
alınır.
</details>

---

## Nasıl çalışır

Serene üç parçadan oluşur ve hepsi aynı bilgisayarda çalışır:

```
┌─────────────────────────────────────────────────────┐
│  Serene.exe  (tek süreç)                            │
│  ├─ Arayüz .............. Flutter (native masaüstü)  │
│  └─ Motor ............... Rust, arayüzün içine gömülü│
│         parçalı indirme · HLS/DASH · kuyruk · köprü   │
└─────────────────────────────────────────────────────┘
        ▲                                    ▲
        │ yerel TCP köprüsü (127.0.0.1)     │ iki turluk onay
┌───────┴──────────┐              ┌──────────┴──────────┐
│  serene-nmh.exe  │              │  "İndirme Bilgileri" │
│  (küçük, hızlı) │              │  (ikinci süreç)     │
└───────┬──────────┘              └─────────────────────┘
        │ native messaging
┌───────┴──────────┐
│  Firefox / Zen   │
│  + eklenti       │
└──────────────────┘
```

**Motor arayüzün içindedir.** Arayüz ile motor arasında soket yoktur; birbirini
doğrudan çağırır. Bu yüzden indirme motoru ayrı bir kurulum gerektirmez.

**Yalnızca tarayıcı köprüsü ayrıdır**, çünkü eklenti onu başlatıp
kendisiyle konuşmak zorunda. Bu ikili küçük ve hızlı açılır; uygulama
çalışmıyorsa sessizce onu başlatır.

**Onay penceresi bilinçli olarak ikinci bir süreçtir.** Ana pencere kapansa
bile onay sorusu yanıtsız kalmaz, ve iki motor aynı görev listesine yazmaz.

### Veriler nerede

| Ne | Nerede |
|---|---|
| Görev listesi | `%APPDATA%\Serene\tasks.json` (yedekli: `tasks.json.bak`) |
| Ayarlar | `%APPDATA%\Serene\settings.json` |
| Yakalanan medya | `%APPDATA%\Serene\captures.json` |
| Yarım indirmeler | indirme klasöründe `.serene/<id>/` |
| Köprü kaydı | `%APPDATA%\Serene\ipc.json` (rastgele port + token) |

Yerel köprü rastgele bir portu dinler ve isteğin rastgele bir **token** ile
doğrulanır; aynı bilgisayardaki başka bir program Serene'e komut gönderemez.

---

## Sınırlar

Dürüst olmak gerekirse:

- **DRM korumalı akışlar indirilemez.** `SAMPLE-AES` gibi şifreli akışlar
  hata mesajıyla durdurulur; çözme yolu yoktur ve eklenmeyecektir.
- **Magnet / torrent bağlantıları reddedilir.**
- **DASH'ta ayrı ses kanalı birleştirilmez.** Video ve ses ayrı AdaptationSet'lerde
  ise yalnızca video indirilir (muxing yapılmaz).
- **Akışlarda toplam boyut ancak bitince bilinir.** İlerleme çubuğu parça
  sayısı üzerinden yürür.
- **Akışlarda parça içi devam yoktur.** Tamamlanmış parçalar korunur, yarım
  kalan parça baştan iner.
- **Kategori yalnızca arayüz filtresidir.** Klasör oluşturmaz.
- **Aynı sunucuya çok sayıda bağlantı** bazı sunucularda 429'a takılabilir;
  ayarlardan bağlantı sayısını düşürebilirsiniz.
- **Eklenti Firefox'un mağazasında yok** (imzasız olduğu için).

---

## Geliştirme

<details>
<summary><b>Gereksinimler</b></summary>

- Rust (stable, 1.77 veya üstü) + Visual Studio Build Tools (C++ iş yükü)
- Flutter 3.47+ (masaüstü Windows desteğiyle) ve Dart 3.13+
- `flutter_rust_bridge_codegen` 2.13.0
- Python 3 + Pillow (yalnızca ikon üretimi ve eklenti paketleme için)
- Node.js (yalnızca doğrulama betikleri ve yayın akışı için)
- NSIS 3 (`winget install NSIS.NSIS`) — yalnızca kurulum paketi için
</details>

<details>
<summary><b>Derleme</b></summary>

```cmd
cd flutter_app
flutter pub get
flutter build windows --release
```

Rust motoru cargokit ile birlikte otomatik derlenir. Tarayıcı köprüsü ayrı:

```cmd
cd native-host
cargo build --release --bin serene-nmh
```

Tam yayın paketi (kurulum paketi + taşınabilir zip + eklenti paketi):

```cmd
node scripts\release.mjs
```

Çıktılar `dist/` altına düşer.
</details>

<details>
<summary><b>Testler</b></summary>

```bash
cd core && cargo test              # 80 test
cd ../native-host && cargo test     # 36 test
cd ../flutter_app && flutter test   # 51 test
```

Uçtan uca doğrulama betikleri gerçek uygulamayı başlatır ve tarayıcı
köprüsüyle konuşur:

```bash
node scripts/check_ffi.mjs         # motor tek exe içinde çalışıyor
node scripts/check_flutter.mjs     # pencere, tek örnek, indirme, onay akışı
node scripts/check_bridge.mjs      # protokol, olay akışı, duraklat/devam
node scripts/check_hls.mjs         # varyant, birleştirme, AES-128, DRM reddi
node scripts/check_dash.mjs        # SegmentTemplate, SegmentTimeline
node scripts/check_captures.mjs    # yakalama tekillestirme, kalıcılık
node scripts/check_nmh.mjs         # native messaging kaydı, sessiz başlatma
node scripts/check_extension.mjs   # eklenti mantığı (tarayıcı taklidiyle)
```

> **Betikler sırayla koşar** ve birbirinin uygulama örneğini açmasını engeller.
> Ayrıntılar `DURUM.md` §6'da.
</details>

<details>
<summary><b>Depo düzeni</b></summary>

| Klasör | İçerik |
|---|---|
| `core/` | İndirme motoru (Rust, ~4.800 satır) — arayüzden bağımsız |
| `flutter_app/lib/` | Arayüz (Dart/Flutter, ~6.100 satır) |
| `flutter_app/rust/` | Motoru arayüze bağlayan FFI katmanı |
| `native-host/` | Tarayıcı köprüsü ikilisi (Rust) |
| `extension/` | Firefox eklentisi (JS) |
| `installer/` | NSIS kurulum paketi |
| `scripts/` | Doğrulama betikleri, ikon üretimi, yayın akışı |
| `ui/` | Tasarım kaynağı ve mockup |
| `docs/superpowers/` | Ürün planı ve faz kayıtları |
| `DURUM.md` | **Ne yapıldı, ne kaldı** — projenin güncel durumu |
</details>

---

## Katkı

Sorun bildirmek veya katkıda bulunmak için depo sayfasındaki
**Issues** ve **Pull requests** bölümlerini kullanın. Ürün bilgisi ve mimari
için `DURUM.md` dosyasına bakın — geliştirme sırasında bilinen tuzaklar
orada toplanmıştır.

---

## Lisans

MIT — bkz. [`LICENSE`](LICENSE). Üçüncü taraf bileşenler
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) dosyasında.

Yazı tipları: Fraunces, Nunito Sans, JetBrains Mono (SIL OFL 1.1) ve
Material Symbols (Apache 2.0).

---

<a name="english"></a>

## English

**Serene** is a download manager for Windows. It aims to be *calm*, not fast:
one window, no clutter, no interruptions.

- **Multi-connection downloads** via HTTP `Range`, **resume** across restarts
- **HLS / DASH** stream downloading with AES-128 decryption
- **Browser takeover** for Firefox/Zen, forwarding `Referer`/`Cookie`/`User-Agent`
  so gated CDNs work; the download waits for your confirmation
- **Media capture** — HLS/DASH streams on a page show up in a *From Browser* panel
- **Clipboard suggestions**, queue with configurable concurrency, categories,
  dark/light theme, Turkish/English UI

> **Not:** the binary is not code-signed, so SmartScreen may warn about an
> unknown publisher. Installation needs no administrator rights.

**Install:** run `Serene-Setup-1.0.0.exe`. The browser extension is optional and
must be loaded manually via `about:debugging` (it is unsigned, so it is not on
the add-on store).

**Limitations:** DRM-protected streams are rejected; magnet links are not
supported; DASH audio is not muxed with video; total stream size is unknown
until the download finishes.

MIT licensed. See [`LICENSE`](LICENSE) and
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
