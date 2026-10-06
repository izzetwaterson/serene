"""Eklenti arayuzu icin Fraunces + Nunito Sans'i woff2'e cevirir.

Kaynak: `flutter_app/assets/fonts` (uygulamayla **ayni** dosyalar; eklenti de
uygulamayla ayni tipografiyi kullansin diye buradan turetilir).

Cikti: `extension/fonts/*.woff2`. Yalnizca kullanilan agirliklar gomulur; woff2
ttf'e gore ~%60 kucuktur (orn. Fraunces-Regular 76 KB -> 29 KB).

Calistirma: python scripts/make_extension_fonts.py
Bagimlilik: fontTools + brotli
"""

import sys
from pathlib import Path

from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "flutter_app" / "assets" / "fonts"
OUT = ROOT / "extension" / "fonts"

FONTS = {
    "Fraunces-Regular.ttf": "fraunces-regular.woff2",
    "NunitoSans-Regular.ttf": "nunito-regular.woff2",
    "NunitoSans-SemiBold.ttf": "nunito-semibold.woff2",
    "NunitoSans-Bold.ttf": "nunito-bold.woff2",
}


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for src_name, out_name in FONTS.items():
        src = SRC / src_name
        if not src.is_file():
            print(f"kaynak yok: {src}", file=sys.stderr)
            return 1
        font = TTFont(str(src))
        font.flavor = "woff2"
        dest = OUT / out_name
        font.save(str(dest))
        print(f"{out_name}: {dest.stat().st_size} bayt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
