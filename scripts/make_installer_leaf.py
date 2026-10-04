"""Kurulum uygulamasi icin yaprak gorsellerini uretir.

Girdi : `ui/serene-leaf.png` — kullanicinin verdigi koyu zumrut yaprak
        (1024x1024, palet + tRNS saydamligi).
Cikti : `installer_app/assets/icons/leaf.png`       aydinlik tema (orijinal ton)
        `installer_app/assets/icons/leaf_dark.png`  karanlik tema (gamma 0.60 ile
                                                      acilmis; koyu zeminde kaybolmasin)

Her ikisi de yaprağin alfa kutusuna kirpilir, kare tuvale %6 bosluk ile
ortalanir ve 640x640'a olceklenir. Deterministiktir.

Calistirma: python scripts/make_installer_leaf.py
Bagimlilik: Pillow + numpy
"""

from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "ui" / "serene-leaf.png"
OUT_DIR = ROOT / "installer_app" / "assets" / "icons"
SIZE = 640
MARGIN = 0.06
DARK_GAMMA = 0.60


def fit(img: Image.Image) -> Image.Image:
    box = img.getchannel("A").getbbox()
    if box is None:
        raise SystemExit("yaprak tamamen saydam: kaynak gecersiz")
    leaf = img.crop(box)
    side = max(leaf.size)
    inner = round(SIZE * (1 - 2 * MARGIN))
    scale = inner / side
    leaf = leaf.resize((round(leaf.width * scale), round(leaf.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    canvas.paste(leaf, ((SIZE - leaf.width) // 2, (SIZE - leaf.height) // 2), leaf)
    return canvas


def lighten(img: Image.Image) -> Image.Image:
    arr = np.asarray(img).astype(np.float32)
    rgb = (arr[..., :3] / 255.0) ** DARK_GAMMA * 255.0
    out = np.concatenate([rgb, arr[..., 3:]], axis=-1)
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGBA")


def main() -> None:
    src = Image.open(SOURCE).convert("RGBA")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    light = fit(src)
    light.save(OUT_DIR / "leaf.png", optimize=True)
    lighten(light).save(OUT_DIR / "leaf_dark.png", optimize=True)
    print(f"yaprak yazildi: {OUT_DIR / 'leaf.png'}, {OUT_DIR / 'leaf_dark.png'}")


if __name__ == "__main__":
    main()
