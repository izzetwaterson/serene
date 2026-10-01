"""Tasarim kaynaklarindan uygulama simgesinin ana dosyalarini uretir.

Girdiler:
  * `ui/serene-leaf.png` — **temiz alfa kanalli yaprak** (1024x1024, palet+tRNS).
    Kullanicinin arka plani kaldirdigi surum. Olculdu: alfa 0..254, koseler tam
    saydam, kenar ortalamasi (22,36,29) govdeden (44,72,56) DAHA KOYU — yani
    beyaz hale yok, kesim temiz.
  * `yeni ikon.jpeg` — alfasiz JPEG (2048x2048): koyu karo uzerinde ayni yaprak.
    Buyuk ana dosya bu fotograftan gelir; karonun kendi dokusu ve isigi korunur.

Cikti  : `ui/serene-icon.png`       — ORIGINAL koyu sanat (48px ve uzeri)
         `ui/serene-icon-small.png` — acik yesil karo + yaprak (48px alti)

**Neden iki ana dosya (kullanici karari, 2026-10-01).** Orijinal koyu karo
oldugu gibi kullanildiginda olculen sonuc:

    acik zemin (L=247) -> Δ211   cok iyi
    koyu zemin (L=32)  -> Δ4     karo cubukla butunlesir

Karo tek renk degil (#2C2930 sol-ust L44 ... #0A090F sag-alt L11) ve dis arka
plan da ayni siyahtir; kompozisyon L~30'da oturur. Windows 11 koyu gorev cubugu
L~32 oldugu icin siluet kaybolur. Gozle gorulen "karo kenari" buyuk olcude
sol-ust parlama sirti + Mach-band etkisidir; olcum dogrulamaz (sag kenar:
L 23,7'ye karsi arka plan 13,3 -> yalniz +10). Kenara ince isik halkasi da
yetmez (olculdu: 4 -> 6, kalin halkayla 14); acik yesil karo 137 verir.

Kullanici karari **karma**: 48px ve uzeri orijinal koyu sanat (Explorer,
kisayol, kurulum — zemin genelde acik), 48px alti acik yesil karolu surum
(gorev cubugu 24px, tepsi 16-24px, eklenti dugmesi). Esik tek yerde:
`KUCUK_ESIK`; `make_icons.py` bu sabiti buradan import eder.

**Yaprak artik kesilmiyor.** Kucuk ana dosyanin yapragi temiz alfa kaynagindan
gelir; JPEG'den yesillik olcutu + morfoloji ile kesme yolu kaldirildi (o yol
1686x1638 / %35,4 uretiyordu ve kose maskesi 33 pikseli kesiyordu). Temiz
kaynakta boyle bir kesim hatasi yoktur.

**Karonun kendi kenari neden kirpilmiyor (buyuk ana dosya):** isik sol-ustten
geliyor, sag/alt kenarda adim yok (olculen `y=1024` profili, sag: 7,4,5,3,2,6,8).
Bu yuzden kutu goruntunun merkezine gore simetrik secilir ve silueti yuvarlak
kose maskesi tanimlar. Kanit: `artifacts/icon-candidates/KENAR-PROOF.png`.

Bu dosya deterministiktir: ayni girdiden ayni ciktiyi uretir. Simgeyi yeniden
uretmek icin once bu, sonra `scripts/make_icons.py` calistirilir.

Bagimlilik: yalniz Pillow + numpy.
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
LEAF_SRC = ROOT / "ui" / "serene-leaf.png"
PHOTO_SRC = ROOT / "yeni ikon.jpeg"
MASTER = ROOT / "ui" / "serene-icon.png"
MASTER_SMALL = ROOT / "ui" / "serene-icon-small.png"

# --- boyut kurali ----------------------------------------------------------
KUCUK_ESIK = 48              # bu boyutun ALTINDA kucuk (acik yesil) ana dosya

# --- ortak olcu -----------------------------------------------------------
MASTER_SIZE = 1024
MARGIN = 0.045               # karonun cevreleyen tuvale gore boslugu (oran)
RADIUS_FRAC = 0.225          # yuvarlak kose yaricapi (karo kenarinin orani)

# --- buyuk ana dosya: orijinal koyu sanat (fotograf) ----------------------
BOX = (170, 170, 1878, 1878)  # olculen karo; merkeze gore simetrik
GREENNESS = 0.05             # yalniz kirpma kontrolu icin

# --- kucuk ana dosya: cizilen acik yesil karo -----------------------------
TILE_TOP = (211, 235, 216)   # primaryFixed #D3EBD8
TILE_BOT = (176, 208, 187)
TILE_EDGE_ALPHA = 26         # acik zeminde karo kenarini belirginlestirir
LEAF_INSET = 0.14            # karo icinde yapragin biraktigi bosluk
GAMMA = 0.60                 # <1 aydinlatir
SATURATION = 1.04

# Kontrast raporlamasi: eski kayitlarla karsilastirilabilsin diye ayni taban.
DARK_BG_LUM = 32
LIGHT_BG_LUM = 247


def _rounded_mask(size: int, radius_frac: float) -> Image.Image:
    """Yuvarlak kose maskesi; 4x supersample ile kenar yumusatilir."""
    ss = 4
    big = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        [0, 0, size * ss - 1, size * ss - 1], radius=int(size * ss * radius_frac), fill=255
    )
    return big.resize((size, size), Image.LANCZOS)


def _gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    strip = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        strip.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return strip.resize((size, size), Image.BILINEAR)


def load_leaf() -> Image.Image:
    """Temiz alfa kaynagindan yapragi alir; kirpar ve aydinlatir."""
    if not LEAF_SRC.exists():
        raise SystemExit(f"yaprak kaynagi yok: {LEAF_SRC}")
    leaf = Image.open(LEAF_SRC).convert("RGBA")

    alpha = np.asarray(leaf)[:, :, 3]
    if alpha.min() > 250:
        raise SystemExit(f"{LEAF_SRC} saydam degil (alfa min {alpha.min()})")
    bbox = leaf.getchannel("A").getbbox()
    if bbox is None:
        raise SystemExit("yaprak kaynaginda opak piksel yok")
    leaf = leaf.crop(bbox)
    print(f"yaprak: kaynak {LEAF_SRC.name}, kirpilmis {leaf.width}x{leaf.height}, "
          f"kutu {bbox}, tuval kapsami %{(alpha > 200).mean() * 100:.1f}")

    # Aydinlat: yalnizca RGB, alfaya dokunma. (Eski JPEG yolunda da gamma 0.60
    # kullaniliyordu; kaynagin ortalama parlakligi da ~56 cikti, gorunum ayni.)
    arr = np.asarray(leaf).astype(np.float32)
    rgb = np.clip(arr[:, :, :3] / 255.0, 0, 1) ** GAMMA * SATURATION
    arr[:, :, :3] = np.clip(rgb * 255.0, 0, 255)
    out = Image.fromarray(arr.astype(np.uint8), "RGBA")

    lum = np.asarray(out)[:, :, :3].mean(axis=2)
    w = np.asarray(out)[:, :, 3] / 255.0
    print(f"yaprak: aydinlatilmis ortalama parlaklik {float((lum * w).sum() / max(w.sum(), 1)):.1f}")
    return out


def build_big() -> Image.Image:
    """Orijinal koyu sanat: fotograftan kirp + yuvarlak kose."""
    if not PHOTO_SRC.exists():
        raise SystemExit(f"tasarim kaynagi yok: {PHOTO_SRC}")
    src = Image.open(PHOTO_SRC)
    if "A" in src.mode:
        raise SystemExit(f"buyuk ana dosya alfasiz JPEG bekler, gelen: {src.mode}")
    tile = src.convert("RGBA").crop(BOX)
    if tile.width != tile.height:
        raise SystemExit(f"kirpma kutusu kare olmali, gelen: {tile.size}")

    # Yaprak kirpma yuzunden bozulmasin. Bu tasarimda yaprak karoyu neredeyse
    # doldurur (yaprak kutusu 1686x1638, karo ~1698); olcut "kesilmemis olmasi".
    a = np.asarray(tile.convert("RGB")).astype(np.float32)
    mx = np.maximum(np.maximum(a[:, :, 0], a[:, :, 1]), a[:, :, 2])
    green = ((a[:, :, 1] - np.maximum(a[:, :, 0], a[:, :, 2])) / np.maximum(mx, 1.0) > GREENNESS)
    ys, xs = np.nonzero(green)
    if len(xs) == 0:
        raise SystemExit("kirpilan bolgede yaprak bulunamadi")
    edge = min(xs.min(), ys.min(), a.shape[1] - 1 - xs.max(), a.shape[0] - 1 - ys.max())
    if edge < 1:
        raise SystemExit(f"yaprak kirpiliyor (en yakin kenar {edge}px) — kutu buyutulmeli")
    print(f"buyuk: yaprak kirpma sonrasi en yakin kenar {edge}px")

    mask = _rounded_mask(tile.width, RADIUS_FRAC)
    cut = int((green & (np.asarray(mask) < 128)).sum())
    pct = cut / max(len(xs), 1) * 100
    print(f"buyuk: kose maskesinin kestigi yaprak pikseli {cut} (%{pct:.3f})")
    if pct > 0.5:
        raise SystemExit(f"kose yaricapi yapragan %{pct:.2f}'sini kesiyor")

    tile.putalpha(mask)
    inner = int(round(MASTER_SIZE * (1 - 2 * MARGIN)))
    canvas = Image.new("RGBA", (MASTER_SIZE, MASTER_SIZE), (0, 0, 0, 0))
    canvas.alpha_composite(tile.resize((inner, inner), Image.LANCZOS),
                           ((MASTER_SIZE - inner) // 2,) * 2)
    return canvas


def build_small(leaf: Image.Image) -> Image.Image:
    """Acik yesil karo + temiz yaprak (48px alti icin okunur surum)."""
    box = int(round(MASTER_SIZE * (1 - 2 * MARGIN)))
    tile = Image.new("RGBA", (box, box), (0, 0, 0, 0))
    tile.paste(_gradient(box, TILE_TOP, TILE_BOT), (0, 0), _rounded_mask(box, RADIUS_FRAC))
    if TILE_EDGE_ALPHA:
        edge = Image.new("RGBA", (box, box), (0, 0, 0, 0))
        ImageDraw.Draw(edge).rounded_rectangle(
            [1, 1, box - 2, box - 2], radius=int(box * RADIUS_FRAC),
            outline=(0, 0, 0, TILE_EDGE_ALPHA), width=max(1, box // 220))
        tile.alpha_composite(edge)

    inner = int(round(box * (1 - 2 * LEAF_INSET)))
    scale = inner / max(leaf.size)
    glyph = leaf.resize((max(1, round(leaf.width * scale)), max(1, round(leaf.height * scale))),
                        Image.LANCZOS)
    tile.alpha_composite(glyph, ((box - glyph.width) // 2, (box - glyph.height) // 2))

    canvas = Image.new("RGBA", (MASTER_SIZE, MASTER_SIZE), (0, 0, 0, 0))
    canvas.alpha_composite(tile, ((MASTER_SIZE - box) // 2,) * 2)
    return canvas


def mean_lum(img: Image.Image, size: int) -> float:
    ic = img.resize((size, size), Image.LANCZOS)
    a = np.asarray(ic).astype(float)
    al = a[:, :, 3] / 255.0
    return float((a[:, :, :3].mean(axis=2) * al).sum() / max(al.sum(), 1.0))


def main() -> None:
    leaf = load_leaf()
    big = build_big()
    small = build_small(leaf)

    for img, name in ((big, MASTER), (small, MASTER_SMALL)):
        corners = [img.getpixel(p)[3] for p in
                   ((1, 1), (img.width - 2, 1), (1, img.height - 2),
                    (img.width - 2, img.height - 2))]
        assert all(c == 0 for c in corners), f"{name}: koseler saydam olmali {corners}"
        name.parent.mkdir(parents=True, exist_ok=True)
        img.save(name)

    print(f"\nbuyuk ana dosya: {MASTER.name}  — orijinal koyu sanat ({KUCUK_ESIK}px ve uzeri)")
    print(f"kucuk ana dosya: {MASTER_SMALL.name} — #%02X%02X%02X karo ({KUCUK_ESIK}px alti)"
          % TILE_TOP)
    print("\nkullanilan  boyut   ortalama L   acik zemin fark   koyu zemin fark")
    for size in (256, 128, 64, 48, 32, 24, 16):
        img = big if size >= KUCUK_ESIK else small
        lum = mean_lum(img, size)
        hangi = "buyuk" if size >= KUCUK_ESIK else "kucuk"
        print(f"  {hangi:6} {size:5}px {lum:12.1f} {abs(lum - LIGHT_BG_LUM):17.0f} "
              f"{abs(lum - DARK_BG_LUM):17.0f}")


if __name__ == "__main__":
    main()
