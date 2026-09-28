# Serene — Organic Design

> **Source of truth:** `flutter_app/lib/src/theme.dart` (implementation) and
> `ui/code.html` (original mockup, still the origin of the layout). This
> document describes what the product actually is today; when code and this file
> disagree, the code is right and this file is the bug.
>
> **Verified against:** `Serene.exe` 1.0.0, Debug build, 1280×880 window,
> 2026-09-28. Token values were read out of `theme.dart` line by line and tab
> contents out of `settings_view.dart`, not from memory.
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

Nothing is sharp. Avoid hard contrasts anywhere.

## Window geometry

| Window | Size | Minimum |
|---|---|---|
| Main | 1280×880 | 940×620 |
| Handoff ("İndirme Bilgileri") | 460×600, vertical | — |

The handoff window is a **second process** (Flutter has no multi-window). It
carries size, category, target folder (editable) and filename (editable).

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
- **Sidebar** — persistent left column: queue filters with live counts
  (including a `fromBrowser` badge for browser captures), category filters,
  disk card.
- **Hero** — when the list is empty, a full-width welcome block: a kicker
  ("Peaceful Download Space"), the Fraunces question, and the URL field. **This
  field is the product's primary action** — there is no separate "start a
  download" button anywhere in the main window (`9c98836` removed it as
  redundant).
- **Settings** — a scrimmed sheet over the main window, not a separate window.
  It is **four tabs**, not one list:

  | Tab | Contents | Count |
  |---|---|---|
  | General | language, appearance (both segmented pickers) | 2 |
  | Downloads | download folder, concurrent downloads, connections per file | 3 |
  | Behaviour | watch clipboard, close to tray, confirm browser downloads, start with Windows | 4 |
  | About | logo, version, engine version, repository link, licence text | — |

  The panel **sizes to its content** (`mainAxisSize.min`) — 2 controls in
  General, 4 toggles in Behaviour — so switching tabs does not leave a sheet
  stretched to the tallest one, and a long tab scrolls internally rather than
  pushing content off the sheet. The About tab shows the app version read from
  `pubspec.yaml` via `build.rs` (never `CARGO_PKG_VERSION`, which is the engine
  and reads 0.1.0), the engine version separately, a link to the repository, and
  the root `LICENSE` embedded at build time by `scripts/embed_license.py`.
- **Tray** — 32×32 RGBA product icon (`assets/icons/serene_tray.png`, the same
  source the window icon uses), tooltip "Serene", "close to tray" by default.
  Its menu is deliberately short — show window, pause all, settings, quit — and
  re-renders whenever a download's state changes, so the pause-all entry cannot
  be a lie.

## Brand outside the window

The product has to look like itself in three places it does not control the
pixels of:

| Surface | Status |
|---|---|
| Window / `.exe` icon | 8-size `.ico` + 32px tray PNG, both generated by `scripts/make_icons.py` from the single master `ui/serene-icon.png` |
| Installer | NSIS Modern UI. The progress page carries a generated banner — the Serene logo over a hairline in `primary`. **No version number in the banner**; it is already in the filename (`Serene-Setup-1.0.0.exe`) |
| Browser extension | **Open gap.** `extension/icons/*.png` is a generic green tile with a white down-arrow — not the leaf, not the palette. It also still reads `0.1.0` while the app is `1.0.0` |

### The icon

A single 3D leaf on transparency, not a flat mark. `scripts/prepare_icon.py`
takes an alpha-channel source, crops to the leaf's bounding box, and applies
**gamma 0.60** before any resize. The gamma is load-bearing: the leaf's mean
luminance is 56, so unadjusted it reads well on cream (contrast 191) and
vanishes on the dark taskbar (contrast 23). At 0.60 it measures 58 on dark and
157 on light. Sharper (0.45) washes out the 3D; softer (0.75) dies at night.

Because the icon is photographic rather than geometric, the earlier rule here —
"generated at `#3D6A4B` with `#D3EBD8` detail, exactly `primary` on
`primaryFixed`" — no longer describes anything. The leaf is *related* to the
palette, not derived from it. Only the installer banner's hairline uses a token
value.

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
  is declared and translated in both languages but no widget references it,
  because the hero field replaced that button. It should be deleted, not left
  to rot — an abstract getter with two implementations reads like a live label
  in review.
- Imagery should feel natural and warm; avoid clinical or tech-stock photos.
  The product ships no photography, which is consistent.

## Known drift

Things this document could not resolve on its own, listed so the next person
does not have to rediscover them:

- The extension icons are off-brand and the extension version is stale
  (`0.1.0` vs the app's `1.0.0`). Both are waiting on the final icon.
- The installer wizard is stock Modern UI. `MUI_BANNER` only styles the progress
  page; the welcome, licence, components and directory pages are Windows'
  chrome. Fully custom pages need `_NSIS.exe` (a compiler built from the NSIS
  source), which is not installed.
