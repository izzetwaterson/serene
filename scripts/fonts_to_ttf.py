"""src/fonts alt kumelerini Flutter icin TTF'e cevirir.

Tarayicida her aile latin / latin-ext gibi ayri woff2 parcalari halinde
geliyor; Flutter tek dosya bekler. Bu betik parcalari birlestirir,
degisken eksenleri (wght/opsz/FILL) istenen statik degerlere sabitler ve
Material Symbols ikon adlarini Dart sabitlerine doker.
"""

import os
import sys
import tempfile

from fontTools.merge import Merger
from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "src", "fonts")
OUT_DIR = os.path.join(ROOT, "flutter_app", "assets", "fonts")
ICON_DART = os.path.join(ROOT, "flutter_app", "lib", "src", "serene_icons.dart")

# (cikti, parcaciklar, eksen degerleri)
JOBS = [
    ("Fraunces-Regular.ttf", ["f005", "f004"], {"wght": 400, "opsz": 24}),
    ("Fraunces-Medium.ttf", ["f005", "f004"], {"wght": 500, "opsz": 24}),
    ("NunitoSans-Regular.ttf", ["f021", "f020"], {"wght": 400}),
    ("NunitoSans-Medium.ttf", ["f021", "f020"], {"wght": 500}),
    ("NunitoSans-SemiBold.ttf", ["f021", "f020"], {"wght": 600}),
    ("NunitoSans-Bold.ttf", ["f021", "f020"], {"wght": 700}),
    ("JetBrainsMono-Regular.ttf", ["f011", "f010"], {"wght": 400}),
    ("JetBrainsMono-Medium.ttf", ["f011", "f010"], {"wght": 500}),
    ("JetBrainsMono-SemiBold.ttf", ["f011", "f010"], {"wght": 600}),
    ("MaterialSymbolsOutlined.ttf", ["f022"], {"FILL": 0, "wght": 400}),
]

# Arayuzde gecen ikon adlari. Malzeme sembollerinde bazi adlar farkli
# oldugu icin esleme burada tutulur.
ICON_ALIASES = {"cloud_queue": "cloud", "draft": "drafts"}

ICON_NAMES = """
spa search tune add_circle cloud_queue autorenew task_alt hourglass_bottom info
travel_explore movie music_note description code folder_zip image hard_drive
eco link create_new_folder download folder edit remove crop_square close pause
play_arrow refresh open_in_new folder_open delete search_off downloading draft
folder_special sync error report warning check_circle schedule check filter_none
""".split()


def save_sfnt(font, path):
    """fontTools, kaynagin tadini (woff2) koruyarak kaydeder; Flutter duz
    sfnt bekler, aksi halde yazi typei sessizce yuklenmiyor."""
    font.flavor = None
    font.flavorData = None
    font.save(path)


def load_merged(parts, axes):
    """Parcalari istenen agirliga sabitleyip tek statik fontta birlestirir."""
    with tempfile.TemporaryDirectory() as temp_dir:
        paths = []
        for name in parts:
            font = TTFont(os.path.join(SRC_DIR, f"{name}.woff2"))
            font = pin_axes(font, axes)
            path = os.path.join(temp_dir, f"{name}.ttf")
            save_sfnt(font, path)
            paths.append(path)

        if len(paths) == 1:
            return TTFont(paths[0])
        return Merger().merge(paths)


def pin_axes(font, want):
    """Tum eksenleri sabitler; kalan varyasyon tablolari birlestirmeyi bozar."""
    if "fvar" not in font:
        return font

    pinned = {a.axisTag: a.defaultValue for a in font["fvar"].axes}
    pinned.update({k: v for k, v in want.items() if k in pinned})
    font = instancer.instantiateVariableFont(font, pinned, inplace=False)
    for tag in ("HVAR", "VVAR", "MVAR", "STAT", "avar", "cvar", "fvar", "gvar"):
        if tag in font:
            del font[tag]
    return font


def subset_icons(font):
    """Ikon yazi tipinde arayuzde kullanilan glifler kalarak kucultulur.
    Ikonlar PUA kod noktalarindan cagrilacagi icin harf gliflerine ve
    ligature tablolarina gerek kalmiyor."""
    glyphs = set(font.getGlyphOrder())
    keep = []
    for name in ICON_NAMES:
        glyph = ICON_ALIASES.get(name, name)
        if glyph in glyphs:
            keep.append(glyph)

    options = Options()
    options.layout_features = []
    subsetter = Subsetter(options=options)
    subsetter.populate(glyphs=keep)
    subsetter.subset(font)
    if "GSUB" in font:
        del font["GSUB"]  # atif yapilmayan glifler kalmis olabilir
    return len(keep)


def build_fonts():
    os.makedirs(OUT_DIR, exist_ok=True)
    for out_name, parts, axes in JOBS:
        font = load_merged(parts, axes)
        if out_name == "MaterialSymbolsOutlined.ttf":
            print(f"  ikon glifleri: {subset_icons(font)} birakildi")
        target = os.path.join(OUT_DIR, out_name)
        save_sfnt(font, target)
        print(f"  {out_name:32s} {os.path.getsize(target):>8,d} bayt  <- {', '.join(parts)}")


def build_icons():
    font = TTFont(os.path.join(SRC_DIR, "f022.woff2"))
    glyphs = set(font.getGlyphOrder())
    reverse = {}
    for code, glyph in font.getBestCmap().items():
        reverse.setdefault(glyph, code)

    lines, missing = [], []
    for name in ICON_NAMES:
        glyph = ICON_ALIASES.get(name, name)
        code = reverse.get(glyph)
        if code is None:
            missing.append(name)
            continue
        lines.append(
            f"  '{name}': IconData(0x{code:x}, fontFamily: 'Material Symbols Outlined'),"
        )

    if missing:
        print(f"  UYARI: kod noktasi bulunamayan ikonlar: {', '.join(missing)}")

    body = "\n".join(lines)
    with open(ICON_DART, "w", encoding="utf-8") as handle:
        handle.write(
            "// Bu dosya scripts/fonts_to_ttf.py tarafindan uretilir; elle duzenlemeyin.\n"
            "// Material Symbols ikon adlarinin kod noktalari.\n\n"
            "import 'package:flutter/widgets.dart';\n\n"
            "const Map<String, IconData> kSereneIcons = {\n"
            f"{body}\n"
            "};\n"
        )
    print(f"  {os.path.basename(ICON_DART):32s} {len(lines)} ikon")
    return not missing


def main():
    print("Fontlar TTF'e cevriliyor:")
    build_fonts()
    print("Ikon kod noktalari yaziliyor:")
    ok = build_icons()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
