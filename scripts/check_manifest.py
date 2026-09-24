"""PE .rsrc bolumunde RT_MANIFEST (tip 24) kaynaklarini arar."""

import struct
import sys


def find_manifest(path):
    with open(path, "rb") as fh:
        data = fh.read()

    pe = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe + 4
    num_sections = struct.unpack_from("<H", coff + 2 and data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    sec_off = opt + opt_size

    for i in range(num_sections):
        base = sec_off + i * 40
        name = data[base : base + 8].rstrip(b"\0").decode("ascii", "replace")
        vsize = struct.unpack_from("<I", data, base + 8)[0]
        va = struct.unpack_from("<I", data, base + 12)[0]
        ssize = struct.unpack_from("<I", data, base + 16)[0]
        praw = struct.unpack_from("<I", data, base + 20)[0]
        if name == ".rsrc":
            rsrc = data[praw : praw + ssize]
            # kaynak dizinini agacsal gez (2 seviye yeter: tip -> isim)
            def parse_dir(off):
                chars, ts, maj, minr, nname, nid = struct.unpack_from("<IIHHHH", rsrc, off)
                entries = []
                for j in range(nname + nid):
                    eoff = off + 16 + j * 8
                    idv, ofsv = struct.unpack_from("<II", rsrc, eoff)
                    entries.append((idv, ofsv))
                return entries

            def resolve(rva):
                return rva - va

            for idv, ofsv in parse_dir(0):
                if idv != 24:  # RT_MANIFEST
                    continue
                for _nid, eofsv in parse_dir(ofsv & 0x7FFFFFFF):
                    for _lang, doff in parse_dir(eofsv & 0x7FFFFFFF):
                        doff_res = doff & 0x7FFFFFFF
                        drva = struct.unpack_from("<I", rsrc, doff_res + 0)[0]
                        dsize = struct.unpack_from("<I", rsrc, doff_res + 4)[0]
                        start = resolve(drva)
                        xml = rsrc[start : start + dsize].decode("utf-8", "replace")
                        return xml
    return None


for exe in sys.argv[1:]:
    try:
        xml = find_manifest(exe)
    except Exception as exc:
        xml = None
        print(exe, "-> hata:", exc)
        continue
    if xml:
        # comctl32 bagimliligini ozetle
        import re

        deps = re.findall(r'type="win32".*?name="([^"]+)"', xml, re.S)
        print(exe, "-> manifest VAR, comctl32:", "Microsoft.Windows.Common-Controls" in str(deps))
    else:
        print(exe, "-> manifest YOK")
