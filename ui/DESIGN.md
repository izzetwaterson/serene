# Serene — Organic Design

> **Source of truth:** `flutter_app/lib/src/theme.dart`. This document describes
> what the product actually is today; when code and this file disagree, the code
> is right and this file is the bug.
>
> **Verified against:** `Serene.exe` 1.0.0, Debug build, windows captured at
> 1280×880 (main), 760×400 (live download) and 460×600 (handoff),
> **2026-10-07**. Token values were read out of `theme.dart` line by line and
> tab contents out of `settings_view.dart`, not from memory. Where this file
> gives a size or a colour it was measured in a captured window on that date,
> not estimated.
>
> **Icon revision 2026-10-12 (leaf everywhere, raw tone):** the product mark is
> the user's own leaf artwork, with no tile and with no tone adjustment, in every
> size — window and `.exe` icon, tray, taskbar, the extension icons, the title
> bar and Settings → About. Before this, the 48 px-and-up frames came from
> THE ICON (the glass leaf on its dark tile), and the leaf used at small sizes
> was gamma-lifted. The tile scores Δ9 against a dark taskbar where the raw leaf
> scores Δ25; the user chose the raw tone and accepted that. "The icon" below
> carries the measurements and the pipeline.
>
> The previous revision of this file was written 46 commits earlier, under the
> working title "Terra", and had drifted on the dark palette, the settings
> structure, the product icon and the default theme. Sections below now carry
> the reasoning behind the choices, so they do not have to be re-derived.

## North Star: "Rooted Warmth"

Calm, grounded, and human. Earthy tones, soft shapes, and natural textures create
a warm, approachable experience. Nothing in the interface should feel like a
sysadmin tool, a browser, or a sci-fi HUD.

## Colors

Two complete palettes ship in the product, selected by the `theme` setting
(`system` / `light` / `dark`).

### Light

| Token | Value | Use |
|---|---|---|
| `background` | `#F7F4ED` | App canvas — warm cream, never sterile white |
| `surfaceContainerLowest` | `#FFFFFF` | Cards, the only true white |
| `surfaceContainer` | `#F2EEE6` | Section fills, sidebar |
| `surfaceContainerHigh` | `#EBE5DC` | Raised tiles |
| `onSurface` | `#2E3230` | Body text |
| `onSurfaceVariant` | `#5F6660` | Secondary text — warm gray, green undertone |
| `outline` | `#8A9088` | Dividers |
| **`primary`** | **`#3D6A4B`** | Forest green: actions, nav, active states |
| `primaryContainer` | `#4A7C59` | Selected/hovered surfaces |
| `primaryFixed` | `#D3EBD8` | Progress track fill, subtle green wash |
| `tertiary` | `#A86B32` | Warm amber: badges, highlights |
| `error` | `#B83230` | Failure states — desaturated, not alarm-red |

### Dark

| Token | Value | Note |
|---|---|---|
| `background` | `#161815` | Warm near-black, **not** `#000` |
| `surfaceContainerLowest` | `#1D1F1B` | Cards |
| `onSurface` | `#E5E4DB` | Body text — warm off-white, not pure |
| **`primary`** | **`#5A8F68`** | Green goes **darker** at night, not lighter — see below |
| `primaryContainer` | `#33543C` | Selected surface; deliberately lightened (the old `#2F5139` gave only 2.00 contrast) |
| `primaryFixed` | `#2F4A35` | Track fill |
| `tertiary` | `#D8A468` | Amber lightens |
| **`onPrimary`** | **`#0B2013`** | Text **on** the green — dark, *not* white |
| `primaryHover` | `#6BA377` | Dark text contrast rises 4.52 → 5.80 |

**The dark green is intentionally the inverse of the light one, and the text
flips with it.** The obvious move — lighten the accent for dark surfaces, keep
white text — fails twice here:

- A light green fill is an *area* of light in a night interface. `#9BD3AC` on
  `#161815` measures **10.47:1**; it is not merely readable, it glares. Every
  filled button becomes a lamp.
- At `#5A8F68` the fill is mid-tone, so white text drops to **3.77:1** (WCAG AA
  needs 4.5) while `#0B2013` reaches **4.52**. So the label has to be dark.

This is the one place where the product inverts a Material default. It is a
decision, not an oversight — do not "fix" it by reverting to white text.

**Rules**

- Every neutral carries a yellow/green undertone. No pure gray, no pure black.
- Nothing is fully saturated. No neon.
- Dark mode is a *designed* palette, not an inverted one: its own primary, its
  own shadow strategy (shadows are stronger — dark surfaces need more
  separation), and its own text polarity.
- Borders are derived from `outlineVariant` at low alpha (`borderSoft` 0x80,
  `borderInput` 0x99, `borderFaint` 0x66, `borderPrimary` 0x33 light / 0x4D dark).

## Defaults

A fresh install starts **light** and **English** (`31b5750`). This is a product
decision, not a fallback: the palette is the brand, and a machine set to dark
should not silently hand a new user a different product. `system` remains
available and follows the OS, re-reading brightness at runtime through
`app_theme.dart`.

## Typography

Four families, all committed as TTF in `flutter_app/assets/fonts/`.

| Role | Family | Weights |
|---|---|---|
| Headlines | **Fraunces** | Regular, Medium |
| Body / labels | **Nunito Sans** | Regular, Medium, SemiBold, Bold |
| Numbers, paths, sizes | **JetBrains Mono** | Regular, Medium, SemiBold |
| Icons | **Material Symbols Outlined** | variable |

- Fraunces is a warm serif — it carries the personality. Used for the app title,
  section headers, and the hero question ("Bugün ne indirmek istersiniz?").
- Nunito Sans is rounded and friendly for everything else.
- JetBrains Mono is **not decorative**: byte counts, speeds, ETAs, file paths,
  the URL field, and the About tab's version/licence text all use it so digits
  align in a column and don't shimmer while a download progresses.
- Icons are Material Symbols codepoints mapped in `lib/src/serene_icons.dart`.
  The font must be loaded or icons silently fall back to a different glyph —
  `test/font_test.dart` guards this.
- Body line-height ≥ 1.6. Generous tracking on small caps labels.

## Elevation

Very soft shadows only. Prefer tonal separation over shadows — layer the warm
cream/green-gray surface steps instead.

| Surface | Light | Dark |
|---|---|---|
| Card (low) | `0x0A3C342A` blur 14 spread −2 offset (0,2) | `0x40000000` blur 14 spread −2 |
| Card (edge) | `0x083C342A` blur 3 offset (0,1) | `0x26000000` blur 3 offset (0,1) |
| Card (high) | `0x1232281E` blur 30 spread −6 offset (0,10) | `0x59000000` blur 30 spread −6 |
| Hover | `0x0A32281E` blur 8 spread −2 | `0x33000000` blur 8 spread −2 |

Shadows are tinted with the palette's own brown-green, never neutral black, in
light mode.

## Shape

| Token | Value | Use |
|---|---|---|
| `radiusCard` | **24** | Task cards, panels, settings sheet |
| `radiusTile` | **16** | Category tiles, completed grid |
| `radiusField` | **12** | Inputs, buttons, chips |
| `radiusControl` | **4** | Micro controls smaller than a field: the `Ctrl K` badge, checkbox boxes |

The first three are surface tiers. `radiusControl` exists because 12 px on a
14 px box is more than half its side and rounds the square into a circle —
the tier below `radiusField` is a different size class, not a smaller field.

Nothing is sharp. Avoid hard contrasts anywhere.

## Window geometry

| Window | Size | Orientation | Minimum |
|---|---|---|---|
| Main | 1280×880 | landscape | 940×620 |
| Handoff ("İndirme Bilgileri") | 460×600 | portrait | — |
| Live download (`--download=<id>`) | **760×400** | **landscape** | — |

All three are frameless where they are secondary; both secondary windows are
**separate processes** (Flutter has no multi-window). The handoff window carries
size, category, target folder (editable) and filename (editable), and pins
Cancel / Download Later / Start Download to the bottom while the middle scrolls,
so the gap under short content is the pinning and not a defect.

The live download window was 520×560 portrait until 2026-10-07. At that width a
16-segment row left each bar ~26 px, and the pill radius turned 26×22 into a
circle — the one view that exists to explain dynamic segmentation showed sixteen
dots, at exactly the segment count the engine reaches after splitting. Landscape
plus 12 px-tall bars fixed both, and the card's meta line stopped being clipped
to "Time left: 14 m …".

**Capturing any of them.** When two Serene processes are alive (main + download,
or main + handoff) capture by id, or you will silently get the main window:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\capture_window.ps1 -ProcessName Serene -Out artifacts\window.png
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\capture_window.ps1 -ProcessId 12345 -Out artifacts\download.png
```

The script refuses to save when the target window is not in the foreground and
rejects a flat image, because both had produced wrong screenshots before. Two
consequences: the desktop has to be free for the second the capture takes, and
**Flutter ignores PostMessage clicks**, so a capture only ever shows a window's
default state. Tab contents other than the active one, hover states and open
menus have to be verified through `flutter test` instead.

## Components

- **Primary button** — solid `primary`, label, 12px radius. Text polarity follows
  the palette: white on the light theme's dark green, `#0B2013` on the dark
  theme's mid green.
- **Secondary button** — `surfaceContainer` fill, `primary` label, `borderInput`.
- **Icon buttons** — circular (`CircleButton` in `lib/src/widgets.dart`), quiet
  until hover, then a `primary` wash. Destructive actions tint toward `error`
  on hover only.
- **Cards** — `surfaceContainerLowest` fill, 24px radius, no harsh border,
  generous padding. A hairline `borderSoft` only where needed for contrast.
- **Inputs** — cream/`surfaceContainerLow` fill, 12px radius, soft green focus
  ring (`primaryFixed`), monospace for URLs.
- **Status chips** — a tinted pill: `statusChip()` in `lib/src/format.dart` picks
  the pair. Awaiting-confirmation and queued use the **amber** tint
  (`tintTertiaryStrong` / `onTertiaryContainer`); downloading and completed use
  the **green** tint (`tintPrimaryStrong` / `onPrimaryFixed`); paused is
  deliberately *quiet* — neutral `surfaceContainer` with `secondary` text, so a
  paused row doesn't compete with running ones; failed uses `tintError` /
  `onErrorContainer`.
- **Progress bars** — thin, rounded, `primaryFixedDim` track with `primary`
  fill. `barTone()` dims rather than re-hues: failed → `error` @ 0.7, completed
  → `primary` @ 0.6, paused → `primary` @ 0.45. Status is carried by the chip
  and the label, not by fighting over the bar color.
- **Segment bars — live download window only.** One bar per connection, in a
  single row, **12 px tall** and ~41 px wide at 760 px. The height is the whole
  point: at 22 px the pill radius turns a ~41 px cell into an oval, and at the
  16 segments dynamic splitting actually reaches it turns ~26 px into a circle.
  The window carries **one** summary line, not two — the card's `metaLine`
  already holds size, speed and ETA, so repeating it under the total bar only
  added noise 60 px below itself.
- **Empty state** — a soft `surfaceContainerLow` panel at 24 px radius: a 48 px
  circle holding a 24 px icon, an 18 px Fraunces line, and a 13 px hint capped
  at 384 px. Vertical padding is **32 px, not 56**: at 56 the panel stood ~234 px
  tall to say two lines; it is ~175 px now.
- **Sidebar** — persistent left column: queue filters with live counts
  (including a `fromBrowser` badge for browser captures), category filters,
  disk card.
- **Hero** — one line of Fraunces above the URL field, and nothing else. **This
  field is the product's primary action** — there is no separate "start a
  download" button anywhere in the main window (`9c98836` removed it as
  redundant). Two things were removed on 2026-10-07: a two-line brand sentence
  under the title, and the green gradient wash behind the block. Both pushed the
  list down ~77 px — one fewer download row fit on screen — and the field's own
  hint already says what to do. A kicker ("Peaceful Download Space") was
  described here until then but had **never been rendered**: the string existed
  and no widget referenced it, which is exactly the drift the "dead strings"
  rule below forbids.
- **Settings** — a scrimmed sheet over the main window, not a separate window.
  It is **four tabs**, not one list:

  | Tab | Contents | Count |
  |---|---|---|
  | General | language, appearance (both segmented pickers) | 2 |
  | Downloads | download folder, concurrent downloads, connections per file | 3 |
  | Behaviour | watch clipboard, close to tray, confirm browser downloads, start with Windows | 4 |
  | About | logo, version, engine version, repository link, licence text | — |

  The panel **sizes to the active tab**: only that tab is built, via a `switch`
  on the tab index. This is load-bearing, not a style choice. Until 2026-10-07
  the tabs lived in an `IndexedStack`, which keeps every tab mounted and takes
  the height of its **tallest** sibling — About, with the licence text — so the
  two-row General tab sat in a ~580 px sheet with ~270 px of dead space under
  APPEARANCE, and the sentence you just read was false. It is ~332 px now. A
  long tab scrolls inside the sheet (capped at `height - 32`) rather than
  pushing content off it, and tab state lives in `_SettingsPanelState`, so a
  direct `switch` gives up only About's scroll offset. The About tab shows the
  app version read from `pubspec.yaml` via `build.rs` (never `CARGO_PKG_VERSION`,
  which is the engine and reads 0.1.0), the engine version separately, a link to
  the repository, and
  the root `LICENSE` embedded at build time by `scripts/embed_license.py`.
- **Tray** — 32×32 RGBA product icon (`assets/icons/serene_tray.png`), the
  **leaf** (32 px sits at the small-surface threshold), tooltip "Serene",
  "close to tray" by default.
  Its menu is deliberately short — show window, pause all, settings, quit — and
  re-renders whenever a download's state changes, so the pause-all entry cannot
  be a lie.

## Brand outside the window

The product has to look like itself in three places it does not control the
pixels of:

| Surface | Status |
|---|---|
| In-app (title bar) | `assets/icons/serene_leaf.png`, 128 px, drawn at 24 logical px. It replaced a Material `spa` glyph inside a tinted circle: the mark is the user's own artwork, not an icon-font approximation |
| In-app (Settings → About) | `assets/icons/serene_logo.png`, 256 px, drawn at 56 logical px — 2× DPI → 112 physical |
| Window / `.exe` icon | 8-size `.ico` (16…256), **every** frame from `ui/serene-leaf-master.png` |
| Tray | `assets/icons/serene_tray.png`, exactly 32 px — Windows' notification area wants 16/20/24/32 |
| Installer | A custom Flutter app (`installer_app/` — the "quiz" layout, 560×420), carried by a silent NSIS stub (`installer/bootstrap.nsi`) that only unpacks and launches it. It **always uses the light palette** (the system dark mode is ignored; there is no theme flag), asks the language on its first page (TR/EN) and uses the standalone leaf (`scripts/make_installer_leaf.py`). **No version number in the artwork** — it is already in the filename (`Serene-Setup-1.0.0.exe`) |
| Browser extension | Generated by `scripts/make_icons.py` — `extension/icons/{16x16,32x32,48x48,96x96,128x128}.png`, all five referenced by `extension/manifest.json`, all five from the leaf. Before 2026-10-01 the set was hand-made and off-brand: a generic green tile with a white down-arrow |

### The icon

The product mark is the user's own artwork: a 3D glass maple leaf, **no tile**.
Two supplied files sit behind it — `ui/serene-icon-source.png` (2048×2048, the
leaf on its dark rounded tile, kept as the artwork it arrived as) and
`ui/serene-leaf.png` (1024×1024, palette + `tRNS` transparency, the leaf alone).

`scripts/prepare_icon.py` turns the leaf into one master,
`ui/serene-leaf-master.png` (1024×1024 RGBA, raw tone, 5 % margin), and
`scripts/make_icons.py` derives **every** size from it: the `.ico`, the tray, the
title-bar mark, the extension set and the About logo. There is no size-based
split any more; the tile left the pipeline on 2026-10-12 at the user's request
("use the leaf everywhere, transparent").

The contrast is measured, not assumed — the same alpha-weighted mean luminance
the icon scripts report:

| Source | Mean L | Light (247) | Dark (32) |
|---|---|---|---|
| Tile + leaf (THE ICON) | 40.5 | Δ206 | **Δ9** |
| Leaf, raw | 57 | Δ190 | Δ25 |
| Leaf, gamma 0.60 (retired) | 98 | Δ149 | Δ66 |

The tile is the best of the three on a light surface and the worst on a dark one;
the leaf inverts that. The gamma-lifted variant held up on both, but it is also a
different colour from the artwork as supplied, so on 2026-10-12 the user chose
the raw tone for every generated file and accepted Δ25 on a dark taskbar. Every
surface now shows the same leaf, at the same tone as the README header.

## Motion

Animation marks a state change; it is never decoration, and it is always
bounded. The app lives in the tray for hours, so anything that repeats forever
keeps waking the renderer while nothing is happening.

| Rule | Why |
|---|---|
| Animate state changes only | The interface is driven by engine events at 2–5 Hz — a 400 ms supervisor tick, a 400 ms window poll, a 500 ms floor on bridge resync, plus 200 ms clocks. At 60 Hz that leaves the frame budget almost untouched between updates, so a short animation is free; an idle loop costs a wake-up per frame. |
| 120–200 ms, once | Long enough to read as motion, short enough to stay out of the way. Past ~250 ms it starts to feel like waiting. |
| Transform and opacity, not layout | Width, height and padding animate through layout on every frame; `Opacity` and `Transform` stay on the compositor. |
| Key inserted rows | New downloads are prepended. An unkeyed insertion makes Flutter re-match by position, so every row below re-animates; `ValueKey(task.id)` keeps the motion on the row that actually appeared. |
| Stagger the first few rows | Rows start 30 ms apart with a small variation so the rhythm does not read as mechanical, flat after the sixth, total under 400 ms. Staggering happens only on the first fill: a new download arrives alone, because a delay repeated on every trigger is an attention cost, not an explanation. |
| Press, do not just hover | A press scales the surface to 0.97 over 150 ms — the baseline for anything the pointer touches. Hover keeps its 120 ms colour shift. |

When the system asks for reduced motion (`MediaQuery.disableAnimations`), the
entrance keeps the fade and drops the translation, and press feedback drops the
scale: the interface still answers, it just stops travelling.

The status chip morphs its background in 180 ms and cross-fades its label in
140 ms, so "Downloading → Paused" reads as a change rather than a swap. The chip
is shared by the task cards, the live download window and the extension offer,
so all three move the same way.

Two animations predate these rules and keep their own shape: the per-segment
bars in the live download window (`AnimatedContainer`, 300–400 ms) and the live
pulse dot (`_PulseDot`, `repeat(reverse: true)`, 1400 ms). The pulse is the only
unbounded animation in the app. It stays because it is on screen only while a
download is running — when the engine is doing I/O anyway — and because turning
it into a fixed number of repeats would read as a flicker rather than a pulse.

## Rules

- Large touch targets, generous spacing. The design should feel breathable.
- Soft over sharp, warm over cool, tonal over bordered.
- Two languages ship (Turkish, English). Every string goes through
  `lib/src/strings.dart` — no hardcoded text in widgets. `Strings` is an
  abstract class with `TrStrings`/`EnStrings` implementations, so a missing
  field is a **compile error**; `test/strings_test.dart` then checks that the
  text actually changes with the language and that locale-aware formatting
  (ETA units, month names, thousand separator) follows.
- Dead strings are a bug, not a leftover. `newDownload` ("Start New Download")
  was declared and translated in both languages while no widget referenced it,
  because the hero field replaced that button. It was deleted on 2026-10-01 —
  an abstract getter with two implementations reads like a live label in
  review. `heroKicker` and `heroBody` followed on 2026-10-07: `heroBody` when
  the hero lost its sentence, `heroKicker` after sitting unreferenced since it
  was written — it had even been documented in this file as if it rendered.
- Imagery should feel natural and warm; avoid clinical or tech-stock photos.
  The product ships no photography, which is consistent.

## Known drift

**Open (2026-10-07):**

- **Two checkbox implementations coexist.** A hand-drawn 14×14 box in the main
  window's settings-row helper, and a scaled Material `Checkbox` in
  `settings_view.dart`. They can drift apart, and merging them needs a visual
  check of the Behaviour tab — which **cannot be captured**, because Flutter
  ignores PostMessage clicks, so it has not been done blind.
- **The handoff payload's `dest` is a full file path**, and the window renders
  `File(dest).parent` as the download folder. Handing it a folder therefore
  shows that folder's parent: silently, and looking entirely correct. Worth
  knowing before building a payload by hand.

**Closed:**

- The extension icon set and version (2026-10-01): icons are generated from the
  project masters and `manifest.json` reads `1.0.0`. The 48/96/128 frames became
  the leaf on 2026-10-12, so the store icon changes with the next release. The extension UI is now
  bilingual too — `_locales/en` + `_locales/tr`, following the browser's
  language with `en` as default, so the "Turkish-only" note that stood here is
  closed.
- The installer (2026-10-01 → 10-04/05): the Modern UI 2 bitmaps were replaced
  outright — the installer is a custom Flutter app carried by a silent NSIS
  stub, and `installer/serene.nsi` / `scripts/make_installer_art.py` were
  **deleted on 2026-10-06**; the `MUI_BANNER` correction went with them.
