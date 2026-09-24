"""Google Fonts CSS'ini indirir, woff2 dosyalarini yerellestirir ve
offline calisan tek bir fonts.css uretir."""

import os
import re
import urllib.request

OUT_DIR = r"C:\Users\ornek\Desktop\serene\src\fonts"
CSS_PATH = r"C:\Users\ornek\Desktop\serene\src\fonts.css"

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

SOURCES = [
    "https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,300..600;1,9..144,300..400&family=Nunito+Sans:ital,opsz,wght@0,6..12,300..700;1,6..12,400&family=JetBrains+Mono:wght@400;500;600&display=swap",
    "https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:wght,FILL@100..700,0..1&display=swap",
]

os.makedirs(OUT_DIR, exist_ok=True)


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


seen = {}
chunks = []

for source in SOURCES:
    css = fetch(source).decode("utf-8")

    def swap(match):
        url = match.group(1)
        if url not in seen:
            name = "f%03d.woff2" % len(seen)
            with open(os.path.join(OUT_DIR, name), "wb") as fh:
                fh.write(fetch(url))
            seen[url] = name
        return "url(fonts/%s)" % seen[url]

    css = re.sub(r"url\((https://[^)]+)\)", swap, css)
    chunks.append(css.strip())

with open(CSS_PATH, "w", encoding="utf-8") as fh:
    fh.write("\n\n".join(chunks) + "\n")

total = sum(
    os.path.getsize(os.path.join(OUT_DIR, f)) for f in os.listdir(OUT_DIR)
)
print("fonts: %d dosya, %.1f KB" % (len(seen), total / 1024.0))
