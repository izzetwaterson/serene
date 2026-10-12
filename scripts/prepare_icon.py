"""Tasarim kaynaklarindan iki ana dosyayi uretir.

Girdi 1: `ui/serene-icon-source.png` — **karo + yaprak, temiz alfa kanalli**
         (2048x2048 RGBA). Kullanicinin "THE ICON" olarak verdigi dosya.
Cikti 1: `ui/serene-icon.png` (1024x1024, RGBA) — karonun tasindigi dosya;
         artik hicbir ikonun kaynagi degil (bkz. 2026-10-12 karari).
Girdi 2: `ui/serene-leaf.png` — arka plani kaldirilmis yaprak (1024x1024,
         palet + tRNS). Kullanicinin temiz alfa kesimi.
Cikti 2: `ui/serene-leaf-master.png` (1024x1024, RGBA) — urunun tek markasi;
         `make_icons.py` butun boyutlari (ikon, tepsi, baslik cubugu, eklenti,
         About) buradan uretir.

**Kullanici karari (2026-10-12): her yerde yaprak, ham tonuyla.** Onceki iki
revizyon — kodla cizilen karo, sonra kullanicinin karo+yaprak gorseli
(2026-10-01) — birakildi. Urunun tek markasi yapraktir ve `make_icons.py` her
boyutu `ui/serene-leaf-master.png`'den uretir. `ui/serene-icon.png` yine
uretilir (karonun tasindigi dosya) ama artik hicbir ikonun kaynagi degildir.

**Neden bu kaynak onceki denemelerden iyi:** onceki koyu karo JPEG'di ve
karonun sag/alt kenari goruntude YOKTU (isik sol-ustten; olculen `y=1024`
profili, sag: 7,4,5,3,2,6,8 — adim yok), bu yuzden karo kodla cizilmek
zorundaydi. Bu dosya PNG ve **gercek alfa** tasiyor:

    alfa 0..255, tuvalin %38,3'u tam saydam, koseler tam saydam
    karo kutusu 1641x1639, tuval merkezinde (1026,1024)
    kenar 4-5 pikselde geciyor — keskin ve temiz

Yani karo kenari artik olculebilir bir sir degil, dosyanin kendisi. Maskeyle
taklit etmeye de gerek yok: olculen kose egrisi dairesel degil (squircle), yani
`rounded_rectangle` ile birebir tutmazdi.

**Olculen kontrast (2026-10-12, ham yaprak).** Alfa agirlikli ortalama
parlaklik 57:

    acik zemin (L=247) -> Δ190   cok iyi
    koyu zemin (L=32)  -> Δ25    zayif

Koyu deger zayiftir cunku yaprak koyu zumrut, Windows 11 koyu gorev cubugu da
koyudur. Onceki zincir bunu gamma 0.60 ile Δ66'ya cikariyordu; kullanici ham
tonu secti ve bedeli kabul etti. Karsilastirma icin: karo+yaprak Δ9. Ayrinti
`ui/DESIGN.md`.

Bu dosya deterministiktir: ayni girdiden ayni ciktiyi uretir. Simgeyi yeniden
uretmek icin once bu, sonra `scripts/make_icons.py` calistirilir.

Bagimlilik: yalniz Pillow + numpy.
"""

from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "ui" / "serene-icon-source.png"
MASTER = ROOT / "ui" / "serene-icon.png"

MASTER_SIZE = 1024
MARGIN = 0.045      # tuvalin her kenarinda birakilan bosluk (oran)

# Yaprak master'i: kaynak yaprak alfa kutusuna kirpilir, %5 kenar bosluguyla
# 1024px tuvale oturtulur. **Gama ve doygunluk notrdur (2026-10-12 kullanici
# karari: "ham ton"), yani master kaynagin rengini birebir tasir.** Onceki
# zincir koyu yuzeyler icin gamma 0.60 uyguluyordu (koyu zeminde Δ66);
# ham ton ayni zeminde Δ25 verir. Kullanici bu bedeli kabul etti.
LEAF_SRC = ROOT / "ui" / "serene-leaf.png"
LEAF_MASTER = ROOT / "ui" / "serene-leaf-master.png"
LEAF_GAMMA = 1.0         # 1.0 = ham ton (aydinlatma yok)
LEAF_SATURATION = 1.0
LEAF_MARGIN = 0.05       # yaprak kenarda %5 boslukla durur

# Kontrast raporlamasi: eski kayitlarla karsilastirilabilsin diye ayni taban.
DARK_BG_LUM = 32
LIGHT_BG_LUM = 247


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"tasarim kaynagi yok: {SOURCE}")

    src = Image.open(SOURCE).convert("RGBA")
    alpha = np.asarray(src)[:, :, 3]
    if alpha.min() > 250:
        raise SystemExit(f"{SOURCE} saydam degil (alfa min {alpha.min()})")

    bbox = src.getchannel("A").getbbox()
    if bbox is None:
        raise SystemExit("kaynaginda opak piksel yok")
    mark = src.crop(bbox)
    print(f"kaynak: {SOURCE.name} {src.width}x{src.height} -> kirpilmis "
          f"{mark.width}x{mark.height}, kutu {bbox}")
    print(f"saydamlik: tuvalin %{(alpha == 0).mean() * 100:.1f}'i tam saydam, "
          f"koseler alfa {[int(alpha[y, x]) for y, x in ((1, 1), (1, -2), (-2, 1), (-2, -2))]}")

    # Kare tuvale sigdir, kenarlarda bosluk birak. Piksele dokunulmaz.
    side = int(max(mark.size) / (1 - 2 * MARGIN))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(mark, ((side - mark.width) // 2, (side - mark.height) // 2))
    canvas = canvas.resize((MASTER_SIZE, MASTER_SIZE), Image.LANCZOS)

    corners = [canvas.getpixel(p)[3] for p in
               ((1, 1), (MASTER_SIZE - 2, 1), (1, MASTER_SIZE - 2),
                (MASTER_SIZE - 2, MASTER_SIZE - 2))]
    assert all(c == 0 for c in corners), f"koseler saydam olmali: {corners}"

    MASTER.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(MASTER, optimize=True)

    print(f"\nana dosya: {MASTER.name} ({MASTER_SIZE}px, RGBA) — karo + yaprak, "
          f"kaynaktan oldugu gibi")
    print(f"yerlesim : kenarda %{MARGIN * 100:.1f} bosluk, simge tuvalin "
          f"%{max(mark.size) / side * 100:.0f}'ini kapliyor")
    print("\nboyut   ortalama L   acik zemin fark   koyu zemin fark")
    for size in (256, 128, 64, 48, 32, 24, 16):
        ic = canvas.resize((size, size), Image.LANCZOS)
        a = np.asarray(ic).astype(float)
        al = a[:, :, 3] / 255.0
        lum = float((a[:, :, :3].mean(axis=2) * al).sum() / max(al.sum(), 1))
        print(f"  {size:3}px {lum:12.1f} {abs(lum - LIGHT_BG_LUM):17.0f} "
              f"{abs(lum - DARK_BG_LUM):17.0f}")

    print("\nAbout yapragi (bilincli istisna — karo degil yaprak):")
    build_leaf_master()


def build_leaf_master() -> None:
    """Yaprak master'ini uretir (bkz. LEAF_* sabitleri).

    Ham yaprak -> RGBA -> alfa kutusuna kirp -> ton ayari -> %5 kenar boslugu
    -> 1024px. Ton ayari su an notr (LEAF_GAMMA/SATURATION = 1.0), yani cikti
    kaynagin rengidir; sabitler eski aydinlatilmis zincire donmek icin durur.
    """
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

    # Aydinlat: yalnizca RGB, alfaya dokunma.
    arr = np.asarray(leaf).astype(np.float32)
    before = float((arr[:, :, :3].mean(axis=2) * (arr[:, :, 3] / 255.0)).sum()
                   / max((arr[:, :, 3] / 255.0).sum(), 1))
    arr[:, :, :3] = np.clip(np.clip(arr[:, :, :3] / 255.0, 0, 1) ** LEAF_GAMMA
                            * LEAF_SATURATION * 255.0, 0, 255)
    leaf = Image.fromarray(arr.astype(np.uint8), "RGBA")
    after = float((arr[:, :, :3].mean(axis=2) * (arr[:, :, 3] / 255.0)).sum()
                  / max((arr[:, :, 3] / 255.0).sum(), 1))
    print(f"yaprak: {LEAF_SRC.name} -> kirpilmis {leaf.width}x{leaf.height}, kutu {bbox}")
    print(f"gamma {LEAF_GAMMA}: ortalama parlaklik {before:.1f} -> {after:.1f}")

    # Kare tuvale sigdir, kenarlarda bosluk birak.
    side = int(max(leaf.size) / (1 - 2 * LEAF_MARGIN))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(leaf, ((side - leaf.width) // 2, (side - leaf.height) // 2))
    canvas = canvas.resize((MASTER_SIZE, MASTER_SIZE), Image.LANCZOS)

    corners = [canvas.getpixel(p)[3] for p in
               ((1, 1), (MASTER_SIZE - 2, 1), (1, MASTER_SIZE - 2),
                (MASTER_SIZE - 2, MASTER_SIZE - 2))]
    assert all(c == 0 for c in corners), f"koseler saydam olmali: {corners}"

    LEAF_MASTER.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(LEAF_MASTER)
    print(f"ana dosya: {LEAF_MASTER.name} ({MASTER_SIZE}px, RGBA) — yalniz yaprak (About)")


if __name__ == "__main__":
    main()
