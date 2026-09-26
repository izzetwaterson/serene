# Urun ikonlarini tek kaynaktan uretir: exe'ye gomulen .ico ve tepsi .png'si.
#
# Kaynak `ui/serene-icon.png` (seffaf arka planli, tasarimdan gelir). Bu betik
# yalnizca o PNG'den turetilen boyutlari yeniden uretir; PNG'ye DOKUNMAZ.
# Ciktilar depoda durur, degisiklik gerekmedikce kosmak gerekmez. Kurulum
# paketi de ayni .ico dosyasini kullanir.
#
# Onceden burada kucuk bir simge CIZILIYORDU; bu, tasarim kaynak dosyasiyla
# cakismaya ve simgenin sessizce degismesine yol acardi. Artik tek gercek
# vardir: `ui/serene-icon.png`.

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "ui" / "serene-icon.png"
ICO = ROOT / "flutter_app" / "windows" / "runner" / "resources" / "app_icon.ico"
TRAY = ROOT / "flutter_app" / "assets" / "icons" / "serene_tray.png"

ICO_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (64, 64),
             (128, 128), (256, 256)]
# 20 ve 24 eklendi: Windows gorev cubugu 24px ister, dosya gezgini 20px. Bu
# kareler olmadan Windows 32'den kucultup bulaniklastiriyordu.


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"kaynak simge yok: {SOURCE}")

    master = Image.open(SOURCE)
    if master.mode != "RGBA":
        raise SystemExit(
            f"kaynak simge saydam olmali (RGBA), gelen: {master.mode}"
        )

    # Kucuk bir kaynak, buyuk boyutlari bulaniklastirir; sessizce bozmayalim.
    if master.width < 512:
        raise SystemExit(
            f"kaynak simge en az 512px olmali, gelen: {master.width}px"
        )

    # ICO: en buyuk boyuttan kucultulur, geri kalan boyutlar buradan turetilir.
    master.resize((256, 256), Image.LANCZOS).save(ICO, sizes=ICO_SIZES)

    # Tepsi: 32px. Kucuk boyutta tasarimin ayrintisi kaybolur; bu yuzden
    # kaynagin kendisi kullanilir, uzerine bir sey cizilmez.
    master.resize((32, 32), Image.LANCZOS).save(TRAY)

    # Yanlis ada yazan bir betik sessizce gecmesin: ciktilar burada dogrulanir.
    sizes = sorted(Image.open(ICO).info["sizes"])
    assert sizes == ICO_SIZES, f"{ICO} boyutlari eksik: {sizes}"
    tray = Image.open(TRAY)
    assert tray.size == (32, 32) and tray.mode == "RGBA", f"{TRAY}: {tray.size} {tray.mode}"
    print(f"ikonlar ok: {ICO.name} {sizes}, {TRAY.name} {tray.size[0]}x{tray.size[1]}")


if __name__ == "__main__":
    main()
