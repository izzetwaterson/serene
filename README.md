<div align="center">
  <img src="ui/serene-leaf.png" width="130" alt="Serene">
  <h3>Serene</h3>
  <p><b>A calm, tidy download manager for Windows.</b></p>
  <p>
    <a href="https://github.com/izzetwaterson/serene/actions/workflows/ci.yml">
      <img src="https://github.com/izzetwaterson/serene/actions/workflows/ci.yml/badge.svg" alt="CI">
    </a>
    <a href="https://github.com/izzetwaterson/serene/releases">
      <img src="https://img.shields.io/github/v/release/izzetwaterson/serene?label=release" alt="Release">
    </a>
  </p>
  <p>Windows 10/11 · MIT licensed · <a href="#turkce">Türkçe</a></p>
</div>

---

A download manager that doesn't try to be fast — it tries to be **calm**: one
window, no clutter, no interruptions. The whole product is a single executable
and the engine runs inside it, so there is no background service and nothing
else to install. Everything stays on your machine: no account, no telemetry.

## What it does

- **Multi-connection downloads** — one file over 8 connections using HTTP
  `Range`, falling back to a single connection when the server doesn't support
  ranges. A segment that stalls is split and re-fetched on a fresh connection.
- **Resumable** — every chunk is written to its own file. Close the app, and it
  picks up where it left off.
- **Streams** — HLS (`m3u8`) and DASH (`mpd`) manifests are fetched, decrypted
  (AES-128) and merged; separate audio tracks are muxed with the bundled
  `ffmpeg` (an external one on `PATH` is used as a fallback).
- **Browser takeover** — start a download in Firefox or Zen and Serene takes it
  over, carrying the page's `Referer`, `Cookie` and `User-Agent` so gated CDNs
  keep working.
- **Confirmed takeover** — a taken-over download waits for a *Download Details*
  window, where you pick the folder and the file name.
- **Media capture** — streams playing on a page appear in a *From Browser*
  panel. Nothing is downloaded without you asking for it.
- **Clipboard suggestions, queue and categories, light and dark theme, English
  and Turkish.**

## Install

Download the latest **`Serene-Setup-<version>.exe`** from the
[Releases](https://github.com/izzetwaterson/serene/releases) page and run it. It
asks for no administrator rights.

| Option | Default |
|---|---|
| Install folder | `%LOCALAPPDATA%\Programs\Serene` |
| Start menu shortcut | on |
| Desktop shortcut | on |
| Start when Windows starts | **off** |

To uninstall, use `Settings → Apps → Serene`. Your download list in
`%APPDATA%\Serene` is preserved.

> **The binaries are not code-signed**, so Windows SmartScreen may warn about an
> unknown publisher. That is deliberate.

![Main window, light theme](artifacts/serene-ekran.png)

### Browser extension (optional)

Serene's extension is published on Firefox Add-ons:

**https://addons.mozilla.org/firefox/addon/serene-download-manager/**

The app offers it once on first launch, and the **Install from Firefox** button
opens that page. Prefer to load it by hand? The installer ships the `extension\`
folder next to `Serene.exe`, and the app's **Open extension folder** button
takes you there.

## Honest limits

- DRM-protected streams (`SAMPLE-AES`) cannot be downloaded, and never will be.
- Magnet and torrent links are rejected.
- A stream's total size is unknown until it finishes.
- Categories are a UI filter only; no folders are created.
- The extension is Firefox-only (Firefox and Zen); there is no Chromium build.
- There is no automatic updater yet — new versions are announced on Releases.

## Building

Rust, Flutter and NSIS are needed; the full pipeline is
`node scripts\release.mjs`, which writes the installer, the portable zip and the
extension package into `dist\`. Setup, tests and the verification scripts are
documented in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [`LICENSE`](LICENSE). Third-party components are listed in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

Fonts: Fraunces, Nunito Sans, JetBrains Mono (SIL OFL 1.1) and Material
Symbols (Apache 2.0).

---

<a name="turkce"></a>

## Türkçe

**Serene**, Windows için tasarlanmış sakin bir indirme yöneticisidir: tek ekran,
sırasız, kesintisiz. Ürünün tamamı tek bir `.exe` içindedir, motor da onun
içinde çalışır — arka planda tutulacak bir servis yoktur. Her şey kendi
makinenizde kalır: hesap yok, telemetri yok.

**Kurulum:** [Releases](https://github.com/izzetwaterson/serene/releases)
sayfasından son sürümün `Serene-Setup-<sürüm>.exe` dosyasını indirip çalıştırın;
yönetici şifresi sorulmaz. Tarayıcı eklentisi isteğe bağlıdır ve Firefox
Add-ons'ta yayındadır.

**Varsayılanlar:** dil İngilizce, tema aydınlık; ikisi de Ayarlar'dan değişir.
Kaynak koddan derlemek için: [CONTRIBUTING.md](CONTRIBUTING.md).
