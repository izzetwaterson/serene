"""Tasarim kaynagindan uygulama simgesinin TEK ana dosyasini uretir.

Girdi  : `ui/serene-leaf.png` — **temiz alfa kanalli yaprak** (1024x1024,
         palet + tRNS). Kullanicinin arka plani kaldirdigi surum.
         Olculdu: alfa 0..254, koseler tam saydam, kenar ortalamasi (22,36,29)
         govdeden (44,72,56) DAHA KOYU — yani beyaz hale yok, kesim temiz.
Cikti  : `ui/serene-icon.png` (1024x1024, RGBA)

**Kullanici karari (2026-10-01): tek kaynak, her yerde bu yaprak.** Karonun
kodla cizilen surumu ve fotograftan gelen koyu karo kaldirildi; simge artik
karo tasimaz, yalnizca yapragi tasir. `ui/serene-icon-small.png` silindi,
`yeni ikon.jpeg` artik betikler tarafindan kullanilmiyor.

**Olculen sonuc (karo kalkinca).** Yapragin alfa agirlikli ortalama parlakligi
kaynaktan oldugu gibi 58,4'tur; bu haliyle koyu zeminde Δ26 verir — yaprak
koyu yesil, gorev cubugu da koyu. Gamma 0.60 ile parlaklik 97,8'e cikar:

    gamma 1.00 -> acik Δ189 / koyu Δ26     en kotu 26
    gamma 0.60 -> acik Δ149 / koyu Δ66     en kotu 66   <-- KULLANILAN
    gamma 0.45 -> acik Δ125 / koyu Δ90     en kotu 90

0.60 secildi: acik zeminde 149 hala cok iyi, koyu zeminde 26 -> 66'ya cikiyor.
Daha sert deger (0.45) koyu zeminde daha iyi ama yapragin koyu yesil karakterini
solduruyor. Karo takan surumlerle karsilastirma (koyu zemin): koyu karo Δ4,
acik yesil karo Δ144, bu yaprak Δ66 — yani karosuz tasarim koyu zeminde koyu
karodan belirgin sekilde iyi, acik karodan zayif.

Bu dosya deterministiktir: ayni girdiden ayni ciktiyi uretir. Simgeyi yeniden
uretmek icin once bu, sonra `scripts/make_icons.py` calistirilir.

Bagimlilik: yalniz Pillow + numpy.
"""

from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
LEAF_SRC = ROOT / "ui" / "serene-leaf.png"
MASTER = ROOT / "ui" / "serene-icon.png"

MASTER_SIZE = 1024
MARGIN = 0.05        # tuvalin her kenarinda birakilan bosluk (oran)
GAMMA = 0.60         # <1 aydinlatir (bkz. docstring: koyu zeminde Δ26 -> Δ66)
SATURATION = 1.04

# Kontrast raporlamasi: eski kayitlarla karsilastirilabilsin diye ayni taban.
DARK_BG_LUM = 32
LIGHT_BG_LUM = 247


def main() -> None:
    if not LEAF_SRC.exists():
        raise SystemExit(f"yaprak kaynagi yok: {LEAF_SRC}")

    src = Image.open(LEAF_SRC).convert("RGBA")
    alpha = np.asarray(src)[:, :, 3]
    if alpha.min() > 250:
        raise SystemExit(f"{LEAF_SRC} saydam degil (alfa min {alpha.min()})")

    bbox = src.getchannel("A").getbbox()
    if bbox is None:
        raise SystemExit("yaprak kaynaginda opak piksel yok")
    leaf = src.crop(bbox)
    print(f"yaprak: {LEAF_SRC.name} -> kirpilmis {leaf.width}x{leaf.height}, kutu {bbox}, "
          f"tuval kapsami %{(alpha > 200).mean() * 100:.1f}")

    # Aydinlat: yalnizca RGB, alfaya dokunma.
    arr = np.asarray(leaf).astype(np.float32)
    before = float((arr[:, :, :3].mean(axis=2) * (arr[:, :, 3] / 255.0)).sum()
                   / max((arr[:, :, 3] / 255.0).sum(), 1))
    arr[:, :, :3] = np.clip(np.clip(arr[:, :, :3] / 255.0, 0, 1) ** GAMMA * SATURATION * 255.0, 0, 255)
    leaf = Image.fromarray(arr.astype(np.uint8), "RGBA")
    after = float((arr[:, :, :3].mean(axis=2) * (arr[:, :, 3] / 255.0)).sum()
                  / max((arr[:, :, 3] / 255.0).sum(), 1))
    print(f"gamma {GAMMA}: ortalama parlaklik {before:.1f} -> {after:.1f}")

    # Kare tuvale sigdir, kenarlarda bosluk birak.
    side = int(max(leaf.size) / (1 - 2 * MARGIN))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(leaf, ((side - leaf.width) // 2, (side - leaf.height) // 2))
    canvas = canvas.resize((MASTER_SIZE, MASTER_SIZE), Image.LANCZOS)

    corners = [canvas.getpixel(p)[3] for p in
               ((1, 1), (MASTER_SIZE - 2, 1), (1, MASTER_SIZE - 2),
                (MASTER_SIZE - 2, MASTER_SIZE - 2))]
    assert all(c == 0 for c in corners), f"koseler saydam olmali: {corners}"

    MASTER.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(MASTER)

    print(f"\nana dosya: {MASTER.name} ({MASTER_SIZE}px, RGBA) — yalniz yaprak, karo yok")
    print(f"yerlesim : kenarda %{MARGIN * 100:.0f} bosluk, yaprak tuvalin "
          f"%{max(leaf.size) / side * 100:.0f}'ini kapliyor")
    print("\nboyut   ortalama L   acik zemin fark   koyu zemin fark")
    for size in (256, 128, 64, 48, 32, 24, 16):
        ic = canvas.resize((size, size), Image.LANCZOS)
        a = np.asarray(ic).astype(float)
        al = a[:, :, 3] / 255.0
        lum = float((a[:, :, :3].mean(axis=2) * al).sum() / max(al.sum(), 1))
        print(f"  {size:3}px {lum:12.1f} {abs(lum - LIGHT_BG_LUM):17.0f} "
              f"{abs(lum - DARK_BG_LUM):17.0f}")


if __name__ == "__main__":
    main()
