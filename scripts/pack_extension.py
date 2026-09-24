#!/usr/bin/env python3
"""Eklentiyi kurulabilir pakete cevirir.

Kullanim: python scripts/pack_extension.py
Cikti: artifacts/serene-<surum>.zip ve artifacts/<eklenti-kimligi>.xpi

Iki dosya da ayni icerigi tasir; `.xpi` adi Firefox'un profilden
sideload icin bekledigi `<kimlik>.xpi` kalibina uyar.
"""

import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "extension")
OUT_DIR = os.path.join(ROOT, "artifacts")


def manifest():
    with open(os.path.join(SRC, "manifest.json"), encoding="utf-8") as fh:
        return json.load(fh)


def entries():
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            full = os.path.join(dirpath, name)
            yield full, os.path.relpath(full, SRC).replace(os.sep, "/")


def write_package(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for full, arc in files:
            zf.write(full, arc)
    return os.path.getsize(path)


def main():
    meta = manifest()
    version = meta.get("version", "0.0.0")
    identity = (
        meta.get("browser_specific_settings", {}).get("gecko", {}).get("id", "")
    )
    if not identity:
        print("BASARISIZ: manifest.json icinde eklenti kimligi yok")
        return 1

    files = list(entries())
    if not any(arc == "manifest.json" for _, arc in files):
        print("BASARISIZ: manifest.json paketin kokunde degil")
        return 1

    os.makedirs(OUT_DIR, exist_ok=True)
    outputs = [
        os.path.join(OUT_DIR, f"serene-{version}.zip"),
        os.path.join(OUT_DIR, f"{identity}.xpi"),
    ]
    for path in outputs:
        size = write_package(path, files)
        print(f"{os.path.relpath(path, ROOT)}  ({size} bayt, {len(files)} dosya)")

    print(f"kimlik: {identity}, surum: {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
