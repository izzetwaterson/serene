"""PE import tablosunu ACIKLAYICI (transitive) olarak gezar: exe'nin
baglandigi DLL'leri ve o DLL'lerin baglandigi DLL'leri de yukleyip
tum semgelerin cozulebildigini dogrular. Ilk basarısız yuklemeyi
tek basina yeniden dener ve hata mesajini dondurur."""

import ctypes
import os
import struct
import sys

k32 = ctypes.WinDLL("kernel32.dll")
k32.GetProcAddress.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
k32.GetProcAddress.restype = ctypes.c_void_p


def parse_imports(path):
    with open(path, "rb") as fh:
        data = fh.read()

    def u16(off):
        return struct.unpack_from("<H", data, off)[0]

    def u32(off):
        return struct.unpack_from("<I", data, off)[0]

    pe = u32(0x3C)
    if data[pe : pe + 4] != b"PE\0\0":
        return None
    coff = pe + 4
    num_sections = u16(coff + 2)
    opt_size = u16(coff + 16)
    opt = coff + 20
    is_pe32_plus = u16(opt) == 0x20B
    dd = opt + (112 if is_pe32_plus else 96)

    sections = []
    sec_off = opt + opt_size
    for i in range(num_sections):
        base = sec_off + i * 40
        sections.append(
            (u32(base + 12), u32(base + 8), u32(base + 20), u32(base + 16))
        )

    def rva_to_off(rva):
        for va, vsize, praw, ssize in sections:
            if va <= rva < va + max(vsize, ssize):
                return praw + (rva - va)
        return None

    def cstr(off):
        end = data.index(b"\0", off)
        return data[off:end].decode("ascii", "replace")

    result = {}
    for table_idx in (1, 13):  # 1: import, 13: delay-load
        table_rva = u32(dd + table_idx * 8)
        if not table_rva:
            continue
        cur = rva_to_off(table_rva)
        entry_size = 20 if table_idx == 1 else 32
        while cur is not None:
            entry = data[cur : cur + entry_size]
            if len(entry) < entry_size or entry == b"\0" * entry_size:
                break
            if table_idx == 1:
                oft, _, _, name_rva, first_thunk = struct.unpack("<IIIII", entry)
            else:
                (_, name_rva, _, iat_rva, int_rva, _, _, _) = struct.unpack("<IIIIIIII", entry)
            name = cstr(rva_to_off(name_rva))
            names = result.setdefault(name, [])
            thunk_rva = (oft or first_thunk) if table_idx == 1 else (int_rva or iat_rva)
            step = 8 if is_pe32_plus else 4
            while True:
                off = rva_to_off(thunk_rva)
                if off is None:
                    break
                value = struct.unpack_from("<Q" if is_pe32_plus else "<I", data, off)[0]
                if value == 0:
                    break
                high = 1 << (63 if is_pe32_plus else 31)
                if not value & high:
                    symbol = cstr(rva_to_off(value) + 2)
                    if symbol not in names:
                        names.append(symbol)
                thunk_rva += step
            cur += entry_size
    return result


def walk(root, search_dirs):
    checked = set()
    queue = [root]
    problems = []
    while queue:
        path = queue.pop(0)
        if path in checked:
            continue
        checked.add(path)

        try:
            imports = parse_imports(path)
        except Exception as exc:
            problems.append(("parse", path, str(exc)))
            continue
        if imports is None:
            continue

        for dll, symbols in imports.items():
            dll_lower = dll.lower()
            try:
                # DLL'i belirli arama dizinleriyle yuklemeyi dene
                handle = None
                for d in [""] + search_dirs:
                    candidate = os.path.join(d, dll) if d else dll
                    try:
                        handle = ctypes.WinDLL(candidate)
                        break
                    except OSError:
                        continue
                if handle is None:
                    raise OSError("yuklenemedi")
            except OSError as exc:
                problems.append(("load", dll, str(exc)))
                continue

            base = ctypes.c_void_p(handle._handle)
            missing = [s for s in symbols if not k32.GetProcAddress(base, s.encode())]
            if missing:
                problems.append(("symbols", dll, ", ".join(missing)))
            else:
                # DLL'in kendi bagliliklarini da kuyruga ekle
                dll_path = getattr(handle, "_name", dll)
                try:
                    found = ctypes.create_unicode_buffer(512)
                    k32.GetModuleFileNameW(
                        ctypes.c_void_p(handle._handle), found, 512
                    )
                    queue.append(found.value)
                except Exception:
                    pass
    return checked, problems


if __name__ == "__main__":
    exe = sys.argv[1]
    dirs = sys.argv[2:]
    checked, problems = walk(exe, dirs)
    print("kontrol edilen modul sayisi:", len(checked))
    for kind, subject, detail in problems:
        print("%-8s %-40s %s" % (kind, subject, detail))
    if not problems:
        print("sorun yok")
