"""Kurulum banner'ini uretir: logo + ince ayirici cizgi.

Cerceve: NSIS Modern UI'nin `MUI_PAGE_INSTFILES` sayfasi. Banner 164 px
yuksekliginde olur, ortada Serene logosu, altinda ince bir ayirici cizgisi.
Geri kalan alan NSIS'in kendi ilerleme cubuguna kalir.

Neden bu boyut: Modern UI'nin sayfa duzeni 164 px'lik ust alan bekler; daha
kucuk banner altta bosluk birakir, daha buyuk sayfayi sikistirir.

Neden sadece logo: surum zaten kurulum dosyasinin adinda gorunuyor
(`Serene-Setup-1.0.0.exe`). Ayrica tekrarlamak bos yer kaplar.

Calistirma: python scripts/make_banner.py
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "flutter_app" / "assets" / "icons" / "serene_tray.png"
OUT_DIR = ROOT / "installer" / "assets"
OUT = OUT_DIR / "banner.bmp"

W, H = 164, 498          # Modern UI sayfa genisligi
LOGO = 72                 # 164px alanda rahat okunur
GAP_ABOVE = 46            # logoyu yukari sabitle, ortalamak yerine ustte birak
RULE_W = 120              # ayirici cizgi genisligi
RULE_H = 1

# Serene paleti (theme.dart ile ayni): krem yuzey, yesil vurgu.
SURFACE = (250, 247, 242)
RULE = (61, 106, 75)     # primary #3D6A4B


def main() -> int:
    if not ICON.is_file():
        print(f"simge yok: {ICON}", file=sys.stderr)
        return 1

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # BMP arka plan (NSIS Banner.dll 24-bit BMP bekler)
    banner = Image.new("RGB", (W, H), SURFACE)
    d = ImageDraw.Draw(banner)

    # Logo: RGBA okunur, alfa ile harmanlanir
    icon = Image.open(ICON).convert("RGBA").resize((LOGO, LOGO), Image.LANCZOS)
    bg = Image.new("RGBA", (LOGO, LOGO), SURFACE + (255,))
    bg.alpha_composite(icon)
    banner.paste(bg.convert("RGB"), ((W - LOGO) // 2, GAP_ABOVE))

    # Ince ayirici cizgi: logonun altinda, ortalanmis
    y = GAP_ABOVE + LOGO + 18
    x0 = (W - RULE_W) // 2
    d.rectangle([x0, y, x0 + RULE_W, y + RULE_H - 1], fill=RULE)

    banner.save(OUT, "BMP")
    print(f"banner yazildi: {OUT.relative_to(ROOT)} ({OUT.stat().st_size} bayt, {W}x{H})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
