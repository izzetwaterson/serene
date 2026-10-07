"""Urun ve eklenti ikonlarini ana dosyalardan uretir.

Iki ana dosya vardir:
  * `ui/serene-icon.png` — karo + yaprak ("THE ICON"). 32px'ten BUYUK kareler
    (gorev cubugu, .ico buyukleri, eklenti buyukleri) buradan turetilir.
  * `ui/serene-leaf-master.png` — yalniz yaprak. 32px ve ALTI kareler ile About
    markasi buradan turetilir: kucuk boyutta karo icindeki yaprak siluetlesip
    kayboluyordu, yaprak ise tuvali doldurdugu icin net kalir. Kullanici
    karari (2026-10-01): About'taki logo degismesin.

Bu betik PNG'lere DOKUNMAZ; yalnizca onlardan turetilen boyutlari uretir.
Ciktilar depoda durur. Ikonlar degistiginde sira:

    python scripts/prepare_icon.py     # kaynaklar -> ui/serene-icon.png,
                                       #              ui/serene-leaf-master.png
    python scripts/make_icons.py       # -> .ico + tepsi + eklenti + About

Uretilenler (kaynak secimi BOYUTA gore: <=32px yaprak, ustu karo+yaprak):
  * `flutter_app/windows/runner/resources/app_icon.ico` (8 boyut)
  * `flutter_app/assets/icons/serene_tray.png` (32px — tepsi)
  * `extension/icons/{16,32,48,96,128}.png`
  * `flutter_app/assets/icons/serene_logo.png` (256px — About, her zaman yaprak)

Tepsi neden 32px, About logosu neden 256px: tepsi tam 32px olmali (Windows
bildirim alani 16/20/24/32 ister), ama About sekmesi logoyu 56 mantiksal px'te
ciziyor — 2x DPI'da 112 fiziksel px. 32px'lik dosyayi 56'ya buyutmek
bulaniklastirirdi; logo bu yuzden 256px uretilir (2x icin 2 kattan fazla pay).

Kaynak secimi BOYUTA gore: <=32px kareler `serene-leaf-master.png` yapragindan,
ustundekiler `serene-icon.png` karo+yapragindan. Kucuk boyutta karo icindeki
yaprak siluetlesip kayboluyordu; yaprak tuvali doldurdugu icin gorev cubugu ve
tepside net kalir. About logosu da her zaman yapraktan gelir (bilincli istisna).

**ICO neden elle yaziliyor.** Pillow'un ICO kaydedicisi tek bir kaynagi
kucultur; `append_images` parametresini kabul ediyor ama ICO icin
KULLANMIYOR (olculdu: uc kareye de ayni goruntuyu koydu). Kareleri acikca
yazmak her boyutu tam denetler ve mevcut `.ico` da zaten 8 karenin tamamini
PNG olarak gomuyordu; bicim ayni tutulur.
"""

import io
import struct
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / "ui" / "serene-icon.png"
LEAF = ROOT / "ui" / "serene-leaf-master.png"
ICO = ROOT / "flutter_app" / "windows" / "runner" / "resources" / "app_icon.ico"
TRAY = ROOT / "flutter_app" / "assets" / "icons" / "serene_tray.png"
LOGO = ROOT / "flutter_app" / "assets" / "icons" / "serene_logo.png"
EXT_ICONS = ROOT / "extension" / "icons"

ICO_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (64, 64),
             (128, 128), (256, 256)]
# 20 ve 24 eklendi: Windows gorev cubugu 24px ister, dosya gezgini 20px. Bu
# kareler olmadan Windows 32'den kucultup bulaniklastiriyordu.

TRAY_SIZE = 32
LOGO_SIZE = 256      # About sekmesi 56 mantiksal px; 2x DPI'da 112 fiziksel
EXT_SIZES = [16, 32, 48, 96, 128]

# Kucuk karelerde karo+yaprak siluetlesip kaybolur; bu esik ve altindaki
# boyutlar YAPRAKTAN uretilir (tuvali doldurur, gorev cubugu/tepsi'de net).
# Ustundekiler karo+yaprak (kimlik). Windows her boyutu kendi secer.
SMALL_FROM_LEAF = 32


def frame(size: int, master: Image.Image) -> Image.Image:
    return master.resize((size, size), Image.LANCZOS)


def _load(path: Path) -> Image.Image:
    if not path.exists():
        raise SystemExit(f"ana dosya yok: {path} (once scripts/prepare_icon.py)")
    img = Image.open(path)
    if img.mode != "RGBA":
        raise SystemExit(f"{path} saydam olmali (RGBA), gelen: {img.mode}")
    # Kucuk bir kaynak, buyuk boyutlari bulaniklastirir; sessizce bozmayalim.
    if img.width < 512:
        raise SystemExit(f"{path} en az 512px olmali, gelen: {img.width}px")
    return img


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
    master = _load(MASTER)
    leaf = _load(LEAF)

    write_ico(ICO, [(w, frame(w, leaf if w <= SMALL_FROM_LEAF else master)) for w, _ in ICO_SIZES])
    TRAY.parent.mkdir(parents=True, exist_ok=True)
    frame(TRAY_SIZE, leaf).save(TRAY)  # tepsi kucuk: yaprak (karo siluetlesirdi)
    # About bilincli istisna: karo degil yaprak. 56 mantiksal px / 2x DPI icin
    # 256px kaynak pay birakiyor.
    frame(LOGO_SIZE, leaf).save(LOGO)

    # Eklenti ikonlari: bu dosyalar onceden ELLE yapilmisti ve marka disiydi
    # (yesil kutu + beyaz asagi ok). Artik ayni kaynaktan uretiliyor.
    EXT_ICONS.mkdir(parents=True, exist_ok=True)
    for size in EXT_SIZES:
        source = leaf if size <= SMALL_FROM_LEAF else master
        frame(size, source).save(EXT_ICONS / f"{size}x{size}.png")

    # Yanlis ada yazan bir betik sessizce gecmesin: ciktilar burada dogrulanir.
    sizes = sorted(Image.open(ICO).info["sizes"])
    if sizes != ICO_SIZES:
        raise SystemExit(f"{ICO} boyutlari eksik: {sizes}")
    tray = Image.open(TRAY)
    if tray.size != (TRAY_SIZE, TRAY_SIZE) or tray.mode != "RGBA":
        raise SystemExit(f"{TRAY}: {tray.size} {tray.mode}")
    logo = Image.open(LOGO)
    if logo.size != (LOGO_SIZE, LOGO_SIZE) or logo.mode != "RGBA":
        raise SystemExit(f"{LOGO}: {logo.size} {logo.mode}")

    def same(img: Image.Image, expect: Image.Image) -> bool:
        return img.convert("RGBA").tobytes() == expect.tobytes()

    for size in (16, 20, 24, 32, 48, 64, 128):
        got = Image.open(io.BytesIO(_ico_frame_bytes(ICO, size)))
        expect = frame(size, leaf if size <= SMALL_FROM_LEAF else master)
        if not same(got, expect):
            raise SystemExit(f"{size}px ICO karesi dogru ana dosyadan gelmemis")
    if not same(Image.open(TRAY), frame(TRAY_SIZE, leaf)):
        raise SystemExit(f"{TRAY_SIZE}px tepsi yaprak ana dosyadan gelmemis")
    if not same(Image.open(LOGO), frame(LOGO_SIZE, leaf)):
        raise SystemExit(f"{LOGO_SIZE}px About logosu yaprak ana dosyadan gelmemis")
    for size in EXT_SIZES:
        got = Image.open(EXT_ICONS / f"{size}x{size}.png")
        expect = frame(size, leaf if size <= SMALL_FROM_LEAF else master)
        if not same(got, expect):
            raise SystemExit(f"eklenti {size}px karesi dogru ana dosyadan gelmemis")

    print(f"ikonlar ok: {ICO.name} {sizes}")
    print(f"           {TRAY.name} {TRAY_SIZE}x{TRAY_SIZE} (tepsi)")
    print(f"           {LOGO.name} {LOGO_SIZE}x{LOGO_SIZE} (About — yaprak)")
    print(f"           extension/icons: {', '.join(f'{s}x{s}.png' for s in EXT_SIZES)}")
    print(f"           iki ana dosya: {MASTER.name} (uygulama+tepsi+eklenti) + "
          f"{LEAF.name} (About)")


if __name__ == "__main__":
    main()
