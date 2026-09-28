"""Kokteki `LICENSE` dosyasini `flutter_app/lib/src/license_text.dart` haline getirir.

Ayarlar > Hakkinda sekmesi lisans metnini gosterir. Metin `rootBundle` ile
okunsa, calisma zamaninda dosya erisimi gerekirdi ve widget testlerinde asset
sistemi kurulu olmadigi icin dogrulanamazdi. Derleme zamaninda gomulmesi hem
test edilebilir hem de uygulamayi tek basina calistirir.

Calistirma:  python scripts/embed_license.py
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "LICENSE"
TARGET = ROOT / "flutter_app" / "lib" / "src" / "license_text.dart"

# Ham dizge (r''' ... ''') kullanilir: cok satirli lisans metninde tirnak,
# ters egrik cizgi ve `$` kacislari dogru durmaz; ham dizgede hicbiri
# yorumlanmaz.
HEADER = """// Lisans metni: kokteki LICENSE dosyasindan uretilir, elle duzenlemeyin.
// Uretmek icin: python scripts/embed_license.py
//
// Neden gomuluyor: metni `rootBundle` ile okumak calisma zamaninda dosya
// erisimi gerektirir ve widget testlerinde asset sistemi kurulu olmadigi
// icin dogrulanamaz. Derleme zamaninda gomulurse hem test edilebilir hem de
// uygulama tek basina calisir.
//
// @generated
const String kLicenseText = r'''
"""


def main() -> int:
    if not SOURCE.is_file():
        print(f"lisans dosyasi yok: {SOURCE}", file=sys.stderr)
        return 1

    text = SOURCE.read_text(encoding="utf-8").strip()
    if not text:
        print("lisans dosyasi bos", file=sys.stderr)
        return 1

    # Ham dizge sinirini bozmamasi icin yalnizca nadir uc durumda elle kapat.
    if "'''" in text:
        print("lisans metni icinde ''' dizgisi var; elle duzelt", file=sys.stderr)
        return 1

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(HEADER + text + "\n''';\n", encoding="utf-8", newline="\n")
    print(f"license_text.dart yazildi ({len(text)} karakter) -> {TARGET.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
