# Urun ikonlarini tek kaynaktan uretir: exe'ye gomulen .ico ve tepsi .png'si.
#
# Ciktilari depoda durur; degisiklik gerekmedikce kosmak gerekmez. Kurulum
# paketi de ayni .ico dosyasini kullanir.

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICO = ROOT / "flutter_app" / "windows" / "runner" / "resources" / "app_icon.ico"
TRAY = ROOT / "flutter_app" / "assets" / "icons" / "serene_tray.png"

ICO_SIZES = [(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]


def icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = int(size * 0.22)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=(61, 106, 75, 255))

    m = size * 0.24
    w = max(1, int(size * 0.07))
    cream = (211, 235, 216, 255)

    # merkezdeki "indirme" oku + taban cizgisi
    cx = size / 2
    d.line([(cx, m * 0.9), (cx, size - m * 1.7)], fill=cream, width=w)
    head = size * 0.17
    tip = size - m * 1.7
    d.line([(cx - head, tip - head), (cx, tip)], fill=cream, width=w)
    d.line([(cx + head, tip - head), (cx, tip)], fill=cream, width=w)
    d.line([(m * 0.95, size - m * 0.95), (size - m * 0.95, size - m * 0.95)], fill=cream, width=w)
    return img


icon(256).save(ICO, sizes=ICO_SIZES)
icon(32).save(TRAY)

# Yanlis ada yazan bir betik sessizce gecmesin: ciktilar burada dogrulanir.
sizes = sorted(Image.open(ICO).info["sizes"])
assert sizes == ICO_SIZES, f"{ICO} boyutlari eksik: {sizes}"
tray = Image.open(TRAY)
assert tray.size == (32, 32) and tray.mode == "RGBA", f"{TRAY}: {tray.size} {tray.mode}"
print(f"ikonlar ok: {ICO.name} {sizes}, {TRAY.name} {tray.size[0]}x{tray.size[1]}")
