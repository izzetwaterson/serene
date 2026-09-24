"""PE import tablosunu okur, her DLL'i yukleyip her simgeyi GetProcAddress ile
cozmeye calisir. Hangi DLL/simgenin eksik oldugunu kesin olarak bulur."""

import ctypes
import struct
import sys

EXE = sys.argv[1]
EXTRA_DIR = sys.argv[2] if len(sys.argv) > 2 else None

if EXTRA_DIR:
    ctypes.windll.kernel32.SetDllDirectoryW(EXTRA_DIR)

with open(EXE, "rb") as fh:
    data = fh.read()


def u16(off):
    return struct.unpack_from("<H", data, off)[0]


def u32(off):
    return struct.unpack_from("<I", data, off)[0]


pe = u32(0x3C)
assert data[pe : pe + 4] == b"PE\0\0", "PE imzasi bulunamadi"
coff = pe + 4
num_sections = u16(coff + 2)
opt_size = u16(coff + 16)
opt = coff + 20
magic = u16(opt)
is_pe32_plus = magic == 0x20B
# veri dizini 1 = import tablosu
dd = opt + (112 if is_pe32_plus else 96)
import_rva = u32(dd + 1 * 8)

sections = []
sec_off = opt + opt_size
for i in range(num_sections):
    base = sec_off + i * 40
    sections.append(
        (
            u32(base + 12),  # VirtualAddress
            u32(base + 8),  # VirtualSize
            u32(base + 20),  # PointerToRawData
            u32(base + 16),  # SizeOfRawData
        )
    )


def rva_to_off(rva):
    for va, vsize, praw, ssize in sections:
        if va <= rva < va + max(vsize, ssize):
            return praw + (rva - va)
    return None


def cstr(off):
    end = data.index(b"\0", off)
    return data[off:end].decode("ascii", "replace")


dlls = {}
cur = rva_to_off(import_rva)
while True:
    entry = data[cur : cur + 20]
    if len(entry) < 20 or entry == b"\0" * 20:
        break
    oft, _, _, name_rva, first_thunk = struct.unpack("<IIIII", entry[:20])
    name = cstr(rva_to_off(name_rva))

    names = []
    thunk_rva = oft or first_thunk
    step = 8 if is_pe32_plus else 4
    while True:
        off = rva_to_off(thunk_rva)
        value = struct.unpack_from("<Q" if is_pe32_plus else "<I", data, off)[0]
        if value == 0:
            break
        high = 1 << (63 if is_pe32_plus else 31)
        if not value & high:
            names.append(cstr(rva_to_off(value) + 2))
        thunk_rva += step
    dlls[name] = names
    cur += 20

# Gecikmeli (delay-load) importlar: veri dizini 13
delay_rva = u32(dd + 13 * 8)
if delay_rva:
    cur = rva_to_off(delay_rva)
    while cur is not None:
        entry = data[cur : cur + 32]
        if len(entry) < 32 or entry == b"\0" * 32:
            break
        _, name_rva, _, iat_rva, int_rva, _, _, _ = struct.unpack("<IIIIIIII", entry)
        name = cstr(rva_to_off(name_rva))
        names = dlls.setdefault(name, [])
        thunk_rva = int_rva or iat_rva
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
        cur += 32

k32 = ctypes.WinDLL("kernel32.dll")
k32.GetProcAddress.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
k32.GetProcAddress.restype = ctypes.c_void_p

problems = 0
for dll, symbols in sorted(dlls.items(), key=lambda kv: kv[0].lower()):
    try:
        handle = ctypes.WinDLL(dll)
    except OSError as exc:
        print("LOAD FAIL  %-45s %s" % (dll, exc))
        problems += 1
        continue
    base = ctypes.c_void_p(handle._handle)
    missing = [s for s in symbols if not k32.GetProcAddress(base, s.encode())]
    if missing:
        print("MISSING    %-45s %s" % (dll, ", ".join(missing[:6])))
        problems += 1

print("\nchecked %d DLLs, %d problem(s)" % (len(dlls), problems))
