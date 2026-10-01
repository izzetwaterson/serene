"""Urun ve eklenti ikonlarini tek kaynaktan uretir.

Kaynak `ui/serene-icon.png` (kullanicinin temiz alfa kanalli yapragi).
Bu betik PNG'ye DOKUNMAZ; yalnizca ondan turetilen boyutlari uretir.
Ciktilar depoda durur. Simge degistiginde sira:

    python scripts/prepare_icon.py     # kaynak -> ui/serene-icon.png
    python scripts/make_icons.py       # -> .ico + tepsi + eklenti ikonlari

Uretilenler:
  * `flutter_app/windows/runner/resources/app_icon.ico` (8 boyut)
  * `flutter_app/assets/icons/serene_tray.png` (32px)
  * `extension/icons/{16,32,48,96,128}.png`

**Tek gercek vardir: `ui/serene-icon.png`.** Her boyut buradan turetilir;
hicbir boyut elle cizilmez ve boyuta gore ayri kaynak secilmez. (Bir ara 48px
alti icin ayri bir "acik yesil karo" ana dosyasi vardi; kullanici tek kaynak
istedigi icin 2026-10-01'de kaldirildi.)

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
ICO = ROOT / "flutter_app" / "windows" / "runner" / "resources" / "app_icon.ico"
TRAY = ROOT / "flutter_app" / "assets" / "icons" / "serene_tray.png"
EXT_ICONS = ROOT / "extension" / "icons"

ICO_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (64, 64),
             (128, 128), (256, 256)]
# 20 ve 24 eklendi: Windows gorev cubugu 24px ister, dosya gezgini 20px. Bu
# kareler olmadan Windows 32'den kucultup bulaniklastiriyordu.

TRAY_SIZE = 32
EXT_SIZES = [16, 32, 48, 96, 128]


def frame(size: int, master: Image.Image) -> Image.Image:
    return master.resize((size, size), Image.LANCZOS)


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
    if not MASTER.exists():
        raise SystemExit(f"kaynak simge yok: {MASTER} (once prepare_icon.py)")

    master = Image.open(MASTER)
    if master.mode != "RGBA":
        raise SystemExit(f"{MASTER} saydam olmali (RGBA), gelen: {master.mode}")
    # Kucuk bir kaynak, buyuk boyutlari bulaniklastirir; sessizce bozmayalim.
    if master.width < 512:
        raise SystemExit(f"{MASTER} en az 512px olmali, gelen: {master.width}px")

    write_ico(ICO, [(w, frame(w, master)) for w, _ in ICO_SIZES])
    TRAY.parent.mkdir(parents=True, exist_ok=True)
    frame(TRAY_SIZE, master).save(TRAY)

    # Eklenti ikonlari: bu dosyalar onceden ELLE yapilmisti ve marka disiydi
    # (yesil kutu + beyaz asagi ok). Artik ayni kaynaktan uretiliyor.
    EXT_ICONS.mkdir(parents=True, exist_ok=True)
    for size in EXT_SIZES:
        frame(size, master).save(EXT_ICONS / f"{size}x{size}.png")

    # Yanlis ada yazan bir betik sessizce gecmesin: ciktilar burada dogrulanir.
    sizes = sorted(Image.open(ICO).info["sizes"])
    if sizes != ICO_SIZES:
        raise SystemExit(f"{ICO} boyutlari eksik: {sizes}")
    tray = Image.open(TRAY)
    if tray.size != (TRAY_SIZE, TRAY_SIZE) or tray.mode != "RGBA":
        raise SystemExit(f"{TRAY}: {tray.size} {tray.mode}")

    def same(img: Image.Image, expect: Image.Image) -> bool:
        return img.convert("RGBA").tobytes() == expect.tobytes()

    for size in (16, 20, 24, 32, 48, 64, 128):
        got = Image.open(io.BytesIO(_ico_frame_bytes(ICO, size)))
        if not same(got, frame(size, master)):
            raise SystemExit(f"{size}px ICO karesi ana dosyadan gelmemis")
    if not same(Image.open(TRAY), frame(TRAY_SIZE, master)):
        raise SystemExit(f"{TRAY_SIZE}px tepsi ana dosyadan gelmemis")
    for size in EXT_SIZES:
        got = Image.open(EXT_ICONS / f"{size}x{size}.png")
        if not same(got, frame(size, master)):
            raise SystemExit(f"eklenti {size}px karesi ana dosyadan gelmemis")

    print(f"ikonlar ok: {ICO.name} {sizes}")
    print(f"           {TRAY.name} {TRAY_SIZE}x{TRAY_SIZE}")
    print(f"           extension/icons: {', '.join(f'{s}x{s}.png' for s in EXT_SIZES)}")
    print(f"           tek kaynak: {MASTER.name} — boyuta gore ayri kaynak YOK")


if __name__ == "__main__":
    main()
