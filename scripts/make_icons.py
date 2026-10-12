"""Urun ve eklenti ikonlarini ana dosyadan uretir.

Tek ana dosya vardir:
  * `ui/serene-leaf-master.png` — yalniz yaprak (1024px, RGBA). 2026-10-12
    kullanici karari: **her yerde yaprak.** Eskiden 32px ustu kareler
    karo+yaprak'tan ("THE ICON") turetilirdi; artik hepsi yapraktan.

Neden yaprak, olculdu: ayni hesap (alfa agirlikli ortalama parlaklik) ile

    kaynak                 ort. L   acik zemin   koyu zemin
    karo + yaprak           40,5     Δ206         Δ9      <- koyu zeminde kayboluyor
    yaprak (ham)            57       Δ190         Δ25
    yaprak (aydinlatilmis)  98       Δ149         Δ66     <- bu dosya

Windows 11'in koyu gorev cubugu ile aydinlatilmis yaprak Δ66 verir; karo+yaprak
Δ9. Yani yaprak hem "karonun icinde siluetlesme" sorununu cozer hem koyu zeminde
daha okunur. Ham yaprak yerine aydinlatilmis master kullanilir cunku ayni
cizimdir, yalnizca koyu yuzeyler icin gama ile acilmistir (bkz.
`scripts/prepare_icon.py`, LEAF_GAMMA = 0.60).

Bu betik PNG'lere DOKUNMAZ; yalnizca onlardan turetilen boyutlari uretir.
Ciktilar depoda durur. Ikonlar degistiginde sira:

    python scripts/prepare_icon.py     # kaynaklar -> ui/serene-leaf-master.png
    python scripts/make_icons.py       # -> .ico + tepsi + eklenti + About

Uretilenler (hepsi yapraktan):
  * `flutter_app/windows/runner/resources/app_icon.ico` (8 boyut)
  * `flutter_app/assets/icons/serene_tray.png` (32px — tepsi)
  * `flutter_app/assets/icons/serene_leaf.png` (128px — baslik cubugu markasi)
  * `extension/icons/{16,32,48,96,128}.png`
  * `flutter_app/assets/icons/serene_logo.png` (256px — About)

Tepsi neden 32px, About logosu neden 256px: tepsi tam 32px olmali (Windows
bildirim alani 16/20/24/32 ister), ama About sekmesi logoyu 56 mantiksal px'te
ciziyor — 2x DPI'da 112 fiziksel px. Baslik cubugu markasi 20 mantiksal px
(2x'te 40 fiziksel); 128px kaynak fazlasiyla yeter.

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
LEAF = ROOT / "ui" / "serene-leaf-master.png"
ICO = ROOT / "flutter_app" / "windows" / "runner" / "resources" / "app_icon.ico"
TRAY = ROOT / "flutter_app" / "assets" / "icons" / "serene_tray.png"
MARK = ROOT / "flutter_app" / "assets" / "icons" / "serene_leaf.png"
LOGO = ROOT / "flutter_app" / "assets" / "icons" / "serene_logo.png"
EXT_ICONS = ROOT / "extension" / "icons"

ICO_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (64, 64),
             (128, 128), (256, 256)]
# 20 ve 24 eklendi: Windows gorev cubugu 24px ister, dosya gezgini 20px. Bu
# kareler olmadan Windows 32'den kucultup bulaniklastiriyordu.

TRAY_SIZE = 32
MARK_SIZE = 128      # baslik cubugu markasi 20 mantiksal px (2x'te 40 fiziksel)
LOGO_SIZE = 256      # About sekmesi 56 mantiksal px; 2x DPI'da 112 fiziksel
EXT_SIZES = [16, 32, 48, 96, 128]


def frame(size: int, leaf: Image.Image) -> Image.Image:
    return leaf.resize((size, size), Image.LANCZOS)


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
    leaf = _load(LEAF)

    write_ico(ICO, [(w, frame(w, leaf)) for w, _ in ICO_SIZES])
    TRAY.parent.mkdir(parents=True, exist_ok=True)
    frame(TRAY_SIZE, leaf).save(TRAY)
    frame(MARK_SIZE, leaf).save(MARK)
    frame(LOGO_SIZE, leaf).save(LOGO)

    EXT_ICONS.mkdir(parents=True, exist_ok=True)
    for size in EXT_SIZES:
        frame(size, leaf).save(EXT_ICONS / f"{size}x{size}.png")

    # Yanlis ada yazan bir betik sessizce gecmesin: ciktilar burada dogrulanir.
    sizes = sorted(Image.open(ICO).info["sizes"])
    if sizes != ICO_SIZES:
        raise SystemExit(f"{ICO} boyutlari eksik: {sizes}")
    for path, size in ((TRAY, TRAY_SIZE), (MARK, MARK_SIZE), (LOGO, LOGO_SIZE)):
        img = Image.open(path)
        if img.size != (size, size) or img.mode != "RGBA":
            raise SystemExit(f"{path}: {img.size} {img.mode}")

    def same(img: Image.Image, expect: Image.Image) -> bool:
        return img.convert("RGBA").tobytes() == expect.tobytes()

    for size, _ in ICO_SIZES:
        got = Image.open(io.BytesIO(_ico_frame_bytes(ICO, size)))
        if not same(got, frame(size, leaf)):
            raise SystemExit(f"{size}px ICO karesi yaprak ana dosyadan gelmemis")
    for path, size in ((TRAY, TRAY_SIZE), (MARK, MARK_SIZE), (LOGO, LOGO_SIZE)):
        if not same(Image.open(path), frame(size, leaf)):
            raise SystemExit(f"{path} yaprak ana dosyadan gelmemis")
    for size in EXT_SIZES:
        got = Image.open(EXT_ICONS / f"{size}x{size}.png")
        if not same(got, frame(size, leaf)):
            raise SystemExit(f"eklenti {size}px karesi yaprak ana dosyadan gelmemis")

    print(f"ikonlar ok: {ICO.name} {sizes} (hepsi yaprak)")
    print(f"           {TRAY.name} {TRAY_SIZE}x{TRAY_SIZE} (tepsi)")
    print(f"           {MARK.name} {MARK_SIZE}x{MARK_SIZE} (baslik cubugu markasi)")
    print(f"           {LOGO.name} {LOGO_SIZE}x{LOGO_SIZE} (About)")
    print(f"           extension/icons: {', '.join(f'{s}x{s}.png' for s in EXT_SIZES)}")
    print(f"           ana dosya: {LEAF.name}")


if __name__ == "__main__":
    main()
