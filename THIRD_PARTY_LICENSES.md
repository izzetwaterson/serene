# Üçüncü Taraf Lisanlar

Serene'nin kendi lisansı MIT'tir (`LICENSE`). Bu dosya, dağıtılan ikili ve
kaynakla birlikte gelen **üçüncü taraf** bileşenleri listeler.

Dağıtım paketi hangi bileşenleri içerir?

| Bileşen | Kurulum paketinde | Gerekçe |
|---|---|---|
| `Serene.exe` | evet | Ürün |
| `rust_lib_serene.dll` | evet | Gömülü Rust motoru |
| `serene-nmh.exe` | evet | Tarayıcı köprüsü |
| `tools\ffmpeg\ffmpeg.exe` | evet | DASH ayrı ses kanalını mux'lamak (LGPL; aşağıda) |
| `flutter_windows.dll`, `data\` | evet | Flutter çalıma zamanı |
| Eklenti paketi (`.xpi`) | ayrı | Kullanıcı tarayıcıya kurar |

Aşağıdaki listeler **ikiliye statik/dinamik olarak bağlanan** ve yeniden
dağıtım koşullarını etkileyen her şeyi kapsar. Geliştirme sırasında kullanılan
ve çıktıya girmeyen araçlar (cargo, cmake, VS Build Tools) listelenmez.

---

## Yazı tipleri

`flutter_app/assets/fonts/` altında TTF olarak depoda durur; uygulama bunları
çalışma zamanında yükler ve ikiliye gömmez. Yine de lisansları geçerlidir.

| Aile | Kullanım | Lisans |
|---|---|---|
| Fraunces | Başlıklar | SIL Open Font License 1.1 |
| Nunito Sans | Gövde metni, etiketler | SIL Open Font License 1.1 |
| JetBrains Mono | Sayılar, yollar, boyutlar | SIL Open Font License 1.1 |
| Material Symbols Outlined | Arayüz ikonları | Apache License 2.0 |

Not: Font dosyaları **altkümelendirilmiş** (subset) sürümlerdir — yalnızca
kullanılan 83 ikon ve kullanılan karakterler vardır. Bu, lisans koşullarını
değiştirmez.

## Rust bağımlılıkları

Çekirdek (`core/`) ve tarayıcı köprüsü (`native-host/`) saf Rust'tır.

| Paket | Sürüm | Lisans |
|---|---|---|
| `serde` | 1.0.229 | MIT OR Apache-2.0 |
| `serde_json` | 1.0.151 | MIT OR Apache-2.0 |
| `tokio` | 1.53.1 | MIT |
| `tokio-util` | 0.7.19 | MIT |
| `futures-util` | 0.3.34 | MIT OR Apache-2.0 |
| `reqwest` | 0.12.28 | MIT OR Apache-2.0 |
| `uuid` | 1.26.1 | Apache-2.0 OR MIT |
| `dirs` | 6.0.0 | MIT OR Apache-2.0 |
| `fs2` | 0.4.3 | MIT/Apache-2.0 |
| `arboard` | 3.6.1 | MIT OR Apache-2.0 |
| `percent-encoding` | 2.3.2 | MIT OR Apache-2.0 |
| `anyhow` | 1.0.104 | MIT OR Apache-2.0 |
| `m3u8-rs` | 6.0.1 | MIT |
| `quick-xml` | 0.42.0 | MIT |
| `aes` | 0.8.4 | MIT OR Apache-2.0 |
| `cbc` | 0.1.2 | MIT OR Apache-2.0 |
| `hex` | 0.4.3 | MIT OR Apache-2.0 |
| `winreg` | 0.55.0 | MIT |

`MIT OR Apache-2.0` ifadesi ikili bir lisansa işaret eder: bu paketler
**ikisinden birini** seçme hakkı verir. Serene Apache-2.0 metnini de
dağıtırsa Apache-2.0, yalnızca MIT metnini dağıtırsa MIT seçilmiş olur;
ikisini birden dağıtmak zorunlu değildir ama mümkündür.

**Kutudan çıkan iki istisna:** `tokio`, `tokio-util`, `m3u8-rs`, `quick-xml`
ve `winreg` yalnızca MIT'tir — onlar için Apache seçimi geçerli değildir.
`fs2` ise `MIT/Apache-2.0` yazıyor, yani aynı seçim kuralı geçerli.

**Dahil edilen Rust paketlerinin tam listesi ve lisansları** üç `Cargo.lock`
ve `cargo metadata` çıktısıdır; Serene'ye özgü bir liste tutmak yerine
doğrudan onları okumak daha güvenlidir.

Tam ve güncel bağımlılık ağacı için üç `Cargo.lock` dosyası tek doğruluk
kaynağıdır: `core/Cargo.lock`, `native-host/Cargo.lock`,
`flutter_app/rust/Cargo.lock`.

## Flutter tarafı ve eklenti

| Paket | Sürüm | Lisans |
|---|---|---|
| `flutter_rust_bridge` | 2.13.0 | MIT |
| cargokit (gömülü, `flutter_app/rust_builder/cargokit/`) | — | MIT |
| Flutter SDK / `flutter_windows.dll` | çalışma zamanı | BSD-3-Clause |

Cargokit `flutter_app/rust_builder/cargokit/` altında **kopyalanmış** olarak
bulunur ve kendi `LICENSE` dosyasını taşır
(`flutter_app/rust_builder/cargokit/LICENSE`, Copyright 2022 Matej Knopp) —
bu metin depoda aynen korunur.

## Doğrudan Dart bağımlılıkları

Paket sürümleri `flutter_app/pubspec.lock` içinde kilitlidir.

| Paket | Sürüm | Lisans |
|---|---|---|
| `window_manager` | 0.5.2 | MIT |
| `tray_manager` | 0.7.0 | MIT |
| `file_picker` | 13.1.0 | MIT |
| `cupertino_icons` | 1.0.9 | MIT |
| `flutter_lints` | 6.0.0 | BSD-3-Clause (yalnız geliştirme) |

`flutter_lints` yalnızca geliştirme sırasında kullanılır, ikiliye girmez.

## Tarayıcı eklentisi

`extension/` içindeki eklenti Serene ile birlikte dağıtılır. Kendi kodu
Serene'nin parçasıdır (MIT) ve harici bir bağımlılığı yoktur; yalnızca
Firefox'in WebExtensions API'sini kullanır.

## FFmpeg (LGPL)

`ffmpeg.exe` kurulum paketiyle **değiştirilmeden** dağıtılır ve yalnızca DASH'ta
ayrı inen video ile sesi **yeniden kodlamadan** (`-c copy`) tek `.mp4`'e
mux'lamak için `core/src/ffmpeg.rs` tarafından çağrılır. Kurulumda uygulamanın
yanındaki **`tools\ffmpeg\` alt klasörüne** konur (ana klasörde dağınık durmasın
diye); bulunamazsa exe yanındaki ya da `PATH`'teki bir ffmpeg'e düşer.

| Alan | Değer |
|---|---|
| Sürüm | FFmpeg n8.1.3 (BtbN FFmpeg-Builds, `autobuild-2026-10-12-13-12`) |
| Build | `ffmpeg-n8.1.3-18-g46d899d7a0-win64-lgpl-8.1.zip` (static, win64) |
| Arşiv SHA-256 | `fa6c5563a794a4dc98cb521e7aad1526004149d308f99ff0ca30159b1451c522` |
| Lisans | **GNU Lesser General Public License v3** (GPL bileşen yok) |
| Kaynak | `https://ffmpeg.org/download.html` · `https://github.com/BtbN/FFmpeg-Builds` |
| Üretim | `node scripts/fetch_ffmpeg.mjs` — indirir, SHA-256 doğrular, yalnız `ffmpeg.exe` çıkarır |

Lisans metni pakete `ffmpeg-LICENSE.txt` olarak dahildir. LGPL yükümlülükleri
karşılanır: ikili değiştirilmez, kaynak adresi verilir, hata ayıklama amaçlı
tersine mühendislik yasaklanmaz.

---

## Bu dosya nasıl güncel tutulur

- Rust tarafında sürümler üç `Cargo.lock` dosyasından okunur.
- Dart tarafında `flutter_app/pubspec.lock`'ten okunur.
- Yazı tipleri `flutter_app/assets/fonts/` altındadır.
- Üçüncü taraf bir bağımlılık eklendiğinde **tabloya eklenir**; bu bir
  dağıtım hukuku kaydıdır, süs değildir.
