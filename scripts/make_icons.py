from PIL import Image, ImageDraw

OUT = r"C:\Users\ornek\Desktop\serene\src-tauri\icons"


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


for name, s in {"32x32.png": 32, "128x128.png": 128, "128x128@2x.png": 256, "icon.png": 512}.items():
    icon(s).save(OUT + "\\" + name)

icon(256).save(
    OUT + r"\icon.ico",
    sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
)
print("icons ok")
