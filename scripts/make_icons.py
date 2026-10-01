"""Urun ve eklenti ikonlarini tek kaynaktan uretir.

Kaynaklar (ikisi de `scripts/prepare_icon.py` ciktisi):
  * `ui/serene-icon.png`       — orijinal koyu sanat
  * `ui/serene-icon-small.png` — acik yesil karo, kucuk boyut icin

Bu betik PNG'lere DOKUNMAZ; yalnizca onlardan turetilen boyutlari uretir.
Ciktilar depoda durur. Simge degistiginde sira:

    python scripts/prepare_icon.py     # kaynak -> ui/serene-icon*.png
    python scripts/make_icons.py       # -> .ico + tepsi + eklenti ikonlari

Uretilenler:
  * `flutter_app/windows/runner/resources/app_icon.ico` (8 boyut)
  * `flutter_app/assets/icons/serene_tray.png` (32px)
  * `extension/icons/{16,32,48,96,128}.png`

**Boyut kurali (kullanici karari, 2026-10-01).** `KUCUK_ESIK` (prepare_icon.py'de
tek yerde sabit) degerinin ALTINDAKI boyutlar acik yesil karolu kucuk ana
dosyadan, o deger ve uzerindekiler orijinal koyu sanattan uretilir. Gerekce
olcum: orijinal koyu karonun ortalama parlakligi ~30'dur; Windows 11 koyu gorev
cubugu L~32 oldugu icin siluet kaybolur (Δ4). Acik yesil karo Δ137 verir.
Gorev cubugu 24px, tepsi 16-24px, eklenti dugmesi 16-32px'tir — yani pratikte
kullanilan boyutlarin tamami esigin altindadir.

**ICO neden elle yaziliyor.** Pillow'un ICO kaydedicisi tek bir kaynagi
kucultur; `append_images` parametresini kabul ediyor ama ICO icin
KULLANMIYOR (olculdu: uc kareye de ayni goruntuyu koydu). Boyut basina ayri
kaynak gerektigi icin kareler burada acikca yazilir. Mevcut `.ico` da zaten
8 karenin tamamini PNG olarak gomuyordu; bicim ayni tutulur.
"""

import io
import struct
from pathlib import Path

from PIL import Image

from prepare_icon import KUCUK_ESIK, MASTER, MASTER_SMALL

ROOT = Path(__file__).resolve().parent.parent
ICO = ROOT / "flutter_app" / "windows" / "runner" / "resources" / "app_icon.ico"
TRAY = ROOT / "flutter_app" / "assets" / "icons" / "serene_tray.png"
EXT_ICONS = ROOT / "extension" / "icons"

ICO_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (64, 64),
             (128, 128), (256, 256)]
# 20 ve 24 eklendi: Windows gorev cubugu 24px ister, dosya gezgini 20px. Bu
# kareler olmadan Windows 32'den kucultup bulaniklastiriyordu.

TRAY_SIZE = 32
EXT_SIZES = [16, 32, 48, 96, 128]


def source_for(size: int, big: Image.Image, small: Image.Image) -> Image.Image:
    """Boyuta gore ana dosya: esigin altinda kucuk, esik ve uzerinde buyuk."""
    return small if size < KUCUK_ESIK else big


def frame(size: int, big: Image.Image, small: Image.Image) -> Image.Image:
    return source_for(size, big, small).resize((size, size), Image.LANCZOS)


def write_ico(path: Path, frames: list[tuple[int, Image.Image]]) -> None:
    """ICO'yu kareleri PNG olarak gomerek yazar (Vista+ bicimi)."""
    blobs: list[tuple[int, bytes]] = []
    for size, img in frames:
        if img.size != (size, size):
            raise SystemExit(f"{size}px kare bekleniyordu, gelen: {img.size}")
        buf = io.BytesIO()
        img.save(buf, format="PNG", optimize=True)
        blobs.append((size, buf.getvalue()))

    # ICONDIR: reserved=0, type=1 (ikon), count
    header = struct.pack("<HHH", 0, 1, len(blobs))
    offset = 6 + 16 * len(blobs)          # ICONDIR + ICONDIRENTRY'ler
    entries = b""
    payload = b""
    for size, data in blobs:
        dim = 0 if size >= 256 else size  # 256 => 0 (1 bayta sigmaz)
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        payload += data
        offset += len(data)
    path.write_bytes(header + entries + payload)


def _ico_frame_bytes(path: Path, size: int) -> bytes:
    """ICO icindeki tek bir karenin ham PNG baytlarini dondurur."""
    raw = path.read_bytes()
    count = struct.unpack_from("<H", raw, 4)[0]
    for i in range(count):
        w, _h, _cc, _rsv, _planes, _bits, nbytes, off = struct.unpack_from(
            "<BBBBHHII", raw, 6 + i * 16
        )
        if (w or 256) == size:
            return raw[off:off + nbytes]
    raise SystemExit(f"{path} icinde {size}px kare yok")


def main() -> None:
    for src in (MASTER, MASTER_SMALL):
        if not src.exists():
            raise SystemExit(f"kaynak simge yok: {src} (once prepare_icon.py)")

    big = Image.open(MASTER)
    small = Image.open(MASTER_SMALL)
    for src, img in ((MASTER, big), (MASTER_SMALL, small)):
        if img.mode != "RGBA":
            raise SystemExit(f"{src} saydam olmali (RGBA), gelen: {img.mode}")
        # Kucuk bir kaynak, buyuk boyutlari bulaniklastirir; sessizce bozmayalim.
        if img.width < 512:
            raise SystemExit(f"{src} en az 512px olmali, gelen: {img.width}px")

    write_ico(ICO, [(w, frame(w, big, small)) for w, _ in ICO_SIZES])
    TRAY.parent.mkdir(parents=True, exist_ok=True)
    frame(TRAY_SIZE, big, small).save(TRAY)

    # Eklenti ikonlari: bu dosyalar onceden ELLE yapilmisti ve marka disiydi
    # (yesil kutu + beyaz asagi ok). Artik ayni kaynaklardan uretiliyor.
    EXT_ICONS.mkdir(parents=True, exist_ok=True)
    for size in EXT_SIZES:
        frame(size, big, small).save(EXT_ICONS / f"{size}x{size}.png")

    # Yanlis ada yazan bir betik sessizce gecmesin: ciktilar burada dogrulanir.
    sizes = sorted(Image.open(ICO).info["sizes"])
    if sizes != ICO_SIZES:
        raise SystemExit(f"{ICO} boyutlari eksik: {sizes}")
    tray = Image.open(TRAY)
    if tray.size != (TRAY_SIZE, TRAY_SIZE) or tray.mode != "RGBA":
        raise SystemExit(f"{TRAY}: {tray.size} {tray.mode}")

    def same(img: Image.Image, expect: Image.Image) -> bool:
        return img.convert("RGBA").tobytes() == expect.tobytes()

    # Kucuk/buyuk secimi sessizce bozulmasin: her iki taraftan da dogrula.
    for size in (16, 20, 24, 32):
        got = Image.open(io.BytesIO(_ico_frame_bytes(ICO, size)))
        if not same(got, frame(size, big, small)):
            raise SystemExit(f"{size}px ICO karesi beklenen kaynaktan gelmemis")
    for size in (48, 64, 128):
        got = Image.open(io.BytesIO(_ico_frame_bytes(ICO, size)))
        if not same(got, frame(size, big, small)):
            raise SystemExit(f"{size}px ICO karesi beklenen kaynaktan gelmemis")
    if not same(Image.open(TRAY), frame(TRAY_SIZE, big, small)):
        raise SystemExit(f"{TRAY_SIZE}px tepsi beklenen kaynaktan gelmemis")
    for size in EXT_SIZES:
        got = Image.open(EXT_ICONS / f"{size}x{size}.png")
        if not same(got, frame(size, big, small)):
            raise SystemExit(f"eklenti {size}px karesi beklenen kaynaktan gelmemis")

    kucuk = [s for s, _ in ICO_SIZES if s < KUCUK_ESIK]
    buyuk = [s for s, _ in ICO_SIZES if s >= KUCUK_ESIK]
    print(f"ikonlar ok: {ICO.name} {sizes}")
    print(f"           {TRAY.name} {TRAY_SIZE}x{TRAY_SIZE}")
    print(f"           extension/icons: {', '.join(f'{s}x{s}.png' for s in EXT_SIZES)}")
    print(f"           esik {KUCUK_ESIK}px -> kucuk karo: {kucuk}, orijinal sanat: {buyuk}")


if __name__ == "__main__":
    main()
