"""Tasarim kaynak dosyasindan uygulama simgesinin ana dosyasini uretir.

Girdi  : `ui/serene-icon-leaf-source.png` — kullanicinin tasarladigi 1024x1024
         PNG. **Alfa kanali var**: arka plan saydam, yalnizca 3B yaprak duruyor.
Cikti : `ui/serene-icon.png` (1024x1024, RGBA)

Iki adim:

1. **Kirp ve ortalagini al.** Yaprak tuvalin yalnizca %54'unu kapliyor; alfa
   kanalinin sinir kutusu alinip bosluk eklenerek yaprak cerceveyi doldurur
   (kenarlarda %14 bosluk birakilir, ikon kenara yapismasin).

2. **Aydinlat.** Yaprak koyu (ortalama parlaklik 56). Aydinlatmazsak acik
   zeminde cok iyi durur (kontrast 191) ama koyu gorev cubugunda kaybolur
   (kontrast 23). Gamma 0.60 ile iki zeminde de okunur hale gelir:
   koyu 58, acik 157. Daha sert degerler (0.45) yapragi soluklastirip 3B
   derinligini bozuyor; daha yumusak degerler (0.75) koyu zeminde zayif kaliyor.

 Neden once kutulu bir ara adim vardi: ilk kaynak `serene-icon.jpg` idi ve
 seffaflik tasimiyordu; kutunun siyah zemini temizleniyor, sonra **yalnizca
 yaprak** istenince kirpma denendi. Yapragin altindaki golge, yapragin
 kendisiyle piksel duzeyinde ayirt edilemiyordu (yesil baskinlik esigi,
 morfoloji, en buyuk bagli bolge ve tasma denendi; bes parametre
 kombinasyonunda da sonuc ince bir hilal ya da yapraga yapisan bir leke
 oldu). Kullanici bu sorunu kendisi cozdu: alfa kanalli kaynak verdi.
 Artik kirpma gerekmiyor.

Bu dosya deterministiktir: ayni girdiden ayni ciktiyi uretir. Ikonu yeniden
uretmek icin once bu, sonra `scripts/make_icons.py` calistirilir.
"""

from pathlib import Path

from PIL import Image
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
LEAF_SOURCE = ROOT / "ui" / "serene-icon-leaf-source.png"
MASTER = ROOT / "ui" / "serene-icon.png"

GAMMA = 0.60       # <1 aydinlatir
SATURATION = 1.04  # hafif doygunluk
MARGIN = 0.14      # cercevenin bir kenari kadar bosluk (oran)
MASTER_SIZE = 1024


def main() -> None:
    if not LEAF_SOURCE.exists():
        raise SystemExit(f"tasarim kaynagi yok: {LEAF_SOURCE}")

    src = Image.open(LEAF_SOURCE)
    if src.mode not in ("RGBA", "LA", "P"):
        raise SystemExit(
            f"kaynak saydam olmali (alfa kanali), gelen mod: {src.mode}"
        )
    leaf = src.convert("RGBA")

    alpha = np.asarray(leaf)[:, :, 3]
    bbox = leaf.getchannel("A").getbbox()
    if bbox is None:
        raise SystemExit("kaynakta saydam olmayan piksel yok")
    leaf = leaf.crop(bbox)
    covered = (np.asarray(leaf)[:, :, 3] > 200).mean() * 100
    print(f"yaprak: {leaf.width}x{leaf.height} (kaynak tuvalin %{covered:.0f} kadarini kapliyordu)")

    # Aydinlat: yalnizca RGB, alfaya dokunma.
    arr = np.asarray(leaf).astype(np.float32)
    rgb = np.clip(arr[:, :, :3] / 255.0, 0, 1) ** GAMMA * SATURATION
    arr[:, :, :3] = np.clip(rgb * 255.0, 0, 255)
    leaf = Image.fromarray(arr.astype(np.uint8), "RGBA")

    # Cerceveye sigdir, kenarlarda bosluk birak.
    side = int(max(leaf.size) / (1 - 2 * MARGIN))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(
        leaf,
        ((side - leaf.width) // 2, (side - leaf.height) // 2),
        leaf,
    )
    canvas = canvas.resize((MASTER_SIZE, MASTER_SIZE), Image.LANCZOS)
    MASTER.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(MASTER)

    out = np.asarray(canvas)
    a = out[:, :, 3]
    corners = [a[1, 1], a[1, -2], a[-2, 1], a[-2, -2]]
    assert all(c == 0 for c in corners), f"koseler saydam olmali: {corners}"
    lum = out[:, :, :3].mean(axis=2)[a > 200]
    # Not: kaynagin en yuksek alfa degeri 254'tur (tam opaga 1 birim kaldi);
    # bu yuzden "== 255" ile olcum yaniltici olur, >= 250 kullanilir.
    print(f"ana dosya: {MASTER.name} ({MASTER_SIZE}px, RGBA)")
    print(f"dogrulama: koseler saydam, yaprak kapsami %{(a >= 250).mean() * 100:.1f}, "
          f"yaprak ortalama parlakligi {lum.mean():.0f}")

    for size in (24, 16):
        ic = canvas.resize((size, size), Image.LANCZOS)
        a2 = np.asarray(ic).astype(float)
        al = a2[:, :, 3] / 255.0
        mean = (a2[:, :, :3].mean(axis=2) * al).sum() / max(al.sum(), 1)
        print(f"  {size}px: koyu zemin kontrast {abs(mean - 32):.0f} | "
              f"acik zemin kontrast {abs(mean - 247):.0f}")


if __name__ == "__main__":
    main()
