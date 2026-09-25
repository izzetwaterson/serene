# Terra — Organic Design

> **Source of truth:** `flutter_app/lib/src/theme.dart` (implementation) and
> `ui/code.html` (original mockup). This document describes what the product
> actually is today; when code and this file disagree, the code is right and
> this file is the bug.
>
> **Verified against:** `Serene.exe` 1.0.0, Debug build, 1280×880 window.

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
| **`primary`** | **`#9BD3AC`** | Green lightens for dark surfaces |
| `tertiary` | `#D8A468` | Amber lightens likewise |
| `onPrimary` | `#0B2013` | Text **on** the green |

**Rules**

- Every neutral carries a yellow/green undertone. No pure gray, no pure black.
- Nothing is fully saturated. No neon.
- Dark mode is a *designed* palette, not an inverted one: it has its own primary
  and its own shadow strategy (shadows are stronger because dark surfaces need
  more separation).
- Borders are derived from `outlineVariant` at low alpha (`borderSoft` 0x80,
  `borderInput` 0x99, `borderFaint` 0x66, `borderPrimary` 0x33).
- The product icon is generated at `#3D6A4B` with `#D3EBD8` detail — i.e. exactly
  `primary` on `primaryFixed`. Brand and UI are one system.

## Typography

Four families, all committed as TTF in `flutter_app/assets/fonts/`.

| Role | Family | Weights |
|---|---|---|
| Headlines | **Fraunces** | Regular, Medium |
| Body / labels | **Nunito Sans** | Regular, Medium, SemiBold, Bold |
| Numbers, paths, sizes | **JetBrains Mono** | Regular, Medium, SemiBold |
| Icons | **Material Symbols Outlined** | variable |

- Fraunces is a warm serif — it carries the personality. Used for the app title,
  section headers, and the empty-state question ("Bugün ne indirmek istersiniz?").
- Nunito Sans is rounded and friendly for everything else.
- JetBrains Mono is **not decorative**: byte counts, speeds, ETAs, file paths
  and the URL field all use it so digits align in a column and don't shimmer
  while a download progresses.
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

## Components

- **Primary button** — solid `primary`, white label, 12px radius, full label
  ("Yeni İndirme Başlat", "İndir").
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
  (including a badge for browser captures), category filters, disk card.
- **Hero** — when the list is empty, a full-width welcome block with the Fraunces
  question and the URL field.
- **Settings** — a scrimmed sheet over the main window, not a separate window.
  Segmented pickers for theme/language, toggles for clipboard/tray/confirm.
- **Handoff window** — "İndirme Bilgileri", vertical, **460×600**, opens as a
  *second process* (Flutter has no multi-window). Shows size, category, target
  folder (editable) and filename (editable).
- **Tray** — 32×32 RGBA product icon, tooltip "Serene", "close to tray" by
  default.

## Rules

- Large touch targets, generous spacing. The design should feel breathable.
- Soft over sharp, warm over cool, tonal over bordered.
- Two languages ship (Turkish, English). Every string goes through
  `lib/src/strings.dart` — no hardcoded text in widgets. `Strings` is an
  abstract class with `TrStrings`/`EnStrings` implementations, so a missing
  field is a **compile error**; `test/strings_test.dart` then checks that the
  text actually changes with the language and that locale-aware formatting
  (ETA units, month names, thousand separator) follows.
- Imagery should feel natural and warm; avoid clinical or tech-stock photos.
  The product currently ships no photography at all, which is consistent.
