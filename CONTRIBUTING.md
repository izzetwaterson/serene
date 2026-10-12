# Contributing

Serene is a Windows download manager built from three pieces. This file is
everything you need to build it, test it and verify a change.

## The pieces

```
+--------------------------------------------------+
|  Serene.exe  (single process)                     |
|  |- Interface ........... Flutter (native desktop)|
|  \- Engine .............. Rust, embedded in the UI|
|         segmented | HLS/DASH | queue | bridge      |
+--------------------------------------------------+
     ^                                    ^
     | local TCP bridge (127.0.0.1)      | two-step consent
+-----------+---+            +-----------+--------+
| serene-nmh.exe |           |  "Download Details" |
| (small, fast) |           |  (second process)   |
+---------+-----+           +---------------------+
          | native messaging
+---------+----------+
| Firefox / Zen     |
| + extension       |
+--------------------+
```

**The engine lives inside the interface.** There is no socket between the UI and
the engine; they call each other directly. That is why the download engine needs
no separate installation.

**Only the browser bridge is separate**, because the extension has to launch it
and talk to it. That binary is small and starts fast; if the app isn't running,
it starts it silently.

**The consent window is deliberately a second process.** If the main window
closes, the question is never left unanswered, and two engines never write to
the same task list.

## Requirements

- Rust (stable, 1.77+) and Visual Studio Build Tools (C++ workload)
- Flutter 3.47+ with desktop Windows support, Dart 3.13+
- `flutter_rust_bridge_codegen` 2.13.0
- Python 3 with Pillow (icon generation and extension packaging only)
- Node.js (verification scripts and the release pipeline only)
- NSIS 3 (`winget install NSIS.NSIS`) — installer packaging only

## Building

```cmd
cd flutter_app
flutter pub get
flutter build windows --release
```

The Rust engine is compiled automatically through cargokit. The browser bridge
is built separately:

```cmd
cd native-host
cargo build --release --bin serene-nmh
```

Full release — installer, portable zip and extension package:

```cmd
node scripts\release.mjs
```

Output lands in `dist/`.

## Tests

```bash
cd core && cargo test               # 87 tests
cd ../native-host && cargo test     # 36 tests
cd ../flutter_app && flutter test   # 61 tests
```

## Verification scripts

The end-to-end scripts launch the real app and talk to it through the same
bridge the browser extension uses:

```bash
node scripts/check_ffi.mjs             # engine runs inside the single exe
node scripts/check_flutter.mjs         # window, single instance, download, consent
node scripts/check_bridge.mjs          # protocol, event stream, pause/resume
node scripts/check_hls.mjs             # variants, merge, AES-128, DRM rejection
node scripts/check_dash.mjs            # SegmentTemplate, SegmentTimeline
node scripts/check_dynamic.mjs         # splitting a segment that stalls
node scripts/check_dynamic_resume.mjs  # a split after a resume never lands on downloaded bytes
node scripts/check_resilience.mjs      # retry, backoff and non-resumable servers
node scripts/check_captures.mjs        # capture dedup, persistence
node scripts/check_nmh.mjs             # native messaging registration, silent start
node scripts/check_extension.mjs       # extension logic (under a browser mock)
```

> **They must run sequentially** and refuse to start while another instance is
> open — close a running Serene first.

`scripts/check_manifest.py` checks the extension package, and
`scripts/serve_hls_test.mjs` serves local HLS fixtures for the stream checks.
`scripts/capture_window.ps1` captures a window for the screenshots in
`artifacts/`; with two Serene processes alive, pass `-ProcessId`, because a name
lookup silently returns the main window.

## Where user data lives

| What | Where |
|---|---|
| Task list | `%APPDATA%\Serene\tasks.json` (with a `.bak` sibling) |
| Settings | `%APPDATA%\Serene\settings.json` |
| Captured media | `%APPDATA%\Serene\captures.json` |
| Partial downloads | `.serene/<id>/` inside the download folder |
| Bridge record | `%APPDATA%\Serene\ipc.json` (random port + token) |

The local bridge listens on a random port and requires a random **token** in
every request, so no other program on your machine can drive Serene.

## Repository layout

| Path | Contents |
|---|---|
| `core/` | Download engine (Rust, ~5,000 lines) — independent of the UI |
| `flutter_app/lib/` | Interface (Dart/Flutter, ~10,600 lines) |
| `flutter_app/rust/` | FFI layer binding the engine to the UI |
| `native-host/` | Browser bridge binary (Rust, ~570 lines) |
| `extension/` | Firefox extension (JavaScript, ~990 lines) |
| `installer_app/` | Installer and uninstaller UI (Flutter) |
| `installer/` | Single-file NSIS carrier (`bootstrap.nsi`, no UI of its own) |
| `scripts/` | Verification scripts, icon generation, release pipeline |
| `ui/` | Design source and the icon masters |

## Before you open a pull request

- `flutter analyze` clean, `flutter test` green, and `cargo test` green in both
  Rust crates.
- Run the verification scripts your change touches. They are the only thing that
  exercises the real window, so they catch what unit tests cannot.
- Commit messages in English.
- Keep the surrounding conventions: code comments are in Turkish, and every
  user-facing string lives in `flutter_app/lib/src/strings.dart` — both
  languages, never a literal inside a widget.
- The version has a single source, `flutter_app/pubspec.yaml`; the installer
  reads it from there.
