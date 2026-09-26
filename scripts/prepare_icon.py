"""Tasarim kaynak dosyasindan uygulama simgesinin ana dosyasini uretir.

Girdi  : `serene-icon.jpg` (kullanicinin tasarladigi 2048x2048 JPEG)
Cikti : `ui/serene-icon.png` (kare, seffaf arka planli, RGBA)

Uc adim, sirasiyla:

1. **Siyah zemin temizlenir.** JPEG seffaflik tasiyamaz ve tasarimin disi
   neredeyse siyah bir zemindir. Kutu yuvarlatilmis bir karedir ve kutunun
   icindeki koyu yesil golgeler disarisiyle ayni parlaklikta oldugu icin basit
   esikleme calismaz. Bunun yerine sinir satir satir taranip bulunur ve o
   sinirin ici doldurulur; boylece kutunun sekli korunur.

2. **Yapraga yakinlastirilir.** Yaprak kutunun yalnizca %58'ini kaliyordu;
   geri kalan %42 bos koyu alan, kucuk boyutta ikonu daha da kucultuyordu.
   1.32 oranla yakinlastirilirca yaprak ~%86'yi kaplar.

3. **Aydinlatilir.** Ikonun ortalama parlakligi ~55 iken Windows 11'in koyu
   gorev cubugu ~32-40; aradaki kontrast neredeyse yoktu ve ikon koyu bir
   leke gibi gorunuyordu. Gamma 0.62 ve %6 doygunluk artisiyla ortalama
   parlaklik ~120'ye cikar.

Bu dosya deterministiktir: ayni girdiden ayni ciktiyi uretir. Ikonu
yeniden uretmek icin once bu, sonra `scripts/make_icons.py` calistirilir.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "serene-icon.jpg"
MASTER = ROOT / "ui" / "serene-icon.png"

THRESHOLD = 27   # kutu disi ~21-25 parlaklikta, kutu ici 37'den yuksek
RUN = 3          # gurultu icin ardisik esik sayisi
ZOOM = 1.32      # 1.0 = yakinlastirma yok
GAMMA = 0.62     # <1 aydinlatir
SATURATION = 1.06
CORNER_RATIO = 0.24
MASTER_SIZE = 1024


def find_tile_bounds(lum):
    """Kutunun sinirini satir satir bulur. Iki yonlu esikleme, cunku kutunun
    icindeki koyu golgeler disarisiyla ayni parlaklikta."""
    height, width = lum.shape
    rows = []
    for y in range(height):
        line = lum[y] > THRESHOLD
        left = next(
            (x for x in range(width)
             if all(line[x + d] for d in range(RUN) if x + d < width)),
            None,
        )
        right = next(
            (x for x in range(width - 1, -1, -1)
             if all(line[x - d] for d in range(RUN) if x - d >= 0)),
            None,
        )
        if left is not None and right is not None and right - left > width * 0.05:
            rows.append((y, left, right))
    if not rows:
        raise SystemExit("kutu siniri bulunamadi; esik degerini gözden geçir")
    x0 = min(r[1] for r in rows)
    x1 = max(r[2] for r in rows)
    return x0, rows[0][0], x1, rows[-1][0]


def rounded_mask(size, ratio=CORNER_RATIO):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * ratio), fill=255)
    return mask.filter(ImageFilter.GaussianBlur(0.6))


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"tasarim kaynagi yok: {SOURCE}")

    src = Image.open(SOURCE).convert("RGB")
    lum = np.asarray(src, dtype=np.float32).mean(axis=2)
    x0, y0, x1, y1 = find_tile_bounds(lum)
    tile = src.crop((x0, y0, x1 + 1, y1 + 1))
    tile = tile.resize((512, 512), Image.LANCZOS).convert("RGBA")
    tile.putalpha(rounded_mask(512))
    print(f"kutu: {x1 - x0 + 1}x{y1 - y0 + 1}")

    if ZOOM > 1.0:
        alpha = np.asarray(tile)[:, :, 3]
        rgb = np.asarray(tile.convert("RGB")).astype(int)
        leaf = (alpha > 40) & (rgb[:, :, 1] > rgb[:, :, 0] + 14) & \
               (rgb[:, :, 1] > rgb[:, :, 2] + 6) & (rgb[:, :, 1] > 40)
        ys, xs = np.where(leaf)
        if len(xs) == 0:
            raise SystemExit("yaprak bulunamadi; yakinlastirma atlandi")
        cx, cy = (xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2
        side = 512 / ZOOM
        left, top = int(cx - side / 2), int(cy - side / 2)
        # Yapragin yeni cerceve icindeki oranini gercekten hesapla: eski
        # genisligini yeni cerceve boyutuna boluyoruz.
        covered = (xs.max() - xs.min() + 1) / side * 100
        tile = tile.crop((left, top, left + side, top + side))
        tile = tile.resize((512, 512), Image.LANCZOS)
        tile.putalpha(rounded_mask(512))
        print(f"yaprak yaklastirmasi: {ZOOM}x (yaprak yeni kutunun %{covered:.0f} kadarini kapliyor)")

    if GAMMA != 1.0 or SATURATION != 1.0:
        arr = np.asarray(tile.convert("RGB")).astype(float)
        arr = 255.0 * np.power(np.clip(arr / 255.0, 0, 1), GAMMA) * SATURATION
        arr = np.clip(arr, 0, 255).astype(np.uint8)
        tile = Image.fromarray(arr, "RGB").convert("RGBA")
        tile.putalpha(rounded_mask(512))
        mean = (np.asarray(tile)[..., :3].mean() * (np.asarray(tile)[..., 3] / 255)).sum() / \
               (np.asarray(tile)[..., 3] / 255).sum()
        print(f"aydinlatma: gamma {GAMMA}, doygunluk x{SATURATION} -> ortalama parlaklik {mean:.0f}")

    tile = tile.resize((MASTER_SIZE, MASTER_SIZE), Image.LANCZOS)
    MASTER.parent.mkdir(parents=True, exist_ok=True)
    tile.save(MASTER)
    print(f"ana dosya: {MASTER} ({MASTER_SIZE}px, RGBA)")

    alpha = np.asarray(tile)[:, :, 3]
    assert alpha[4, 4] == 0, "koseler saydam olmali"
    print(f"dogrulama: kose alfa={alpha[4, 4]}, saydam piksel orani={(alpha == 0).mean() * 100:.1f}%")


if __name__ == "__main__":
    main()
