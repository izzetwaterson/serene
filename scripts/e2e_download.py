"""Ucstan uca indirme testi: uygulamayi baslatir, URL girisini klavyeyle
doldurur, Enter ile indirmeyi tetikler, dosyanin inmesini bekler."""

import ctypes
import os
import subprocess
import sys
import time

from PIL import ImageGrab

# Baska bir derlemeyi denemek icin: SERENE_EXE=...\target\release\serene.exe
EXE = os.environ.get("SERENE_EXE") or (
    r"C:\Users\ornek\Desktop\serene\src-tauri\target\debug\serene.exe"
)
CWD = r"C:\Users\ornek\Desktop\serene\src-tauri"
SHOT = r"C:\Users\ornek\Desktop\serene\artifacts\serene-download.png"
URL = sys.argv[1] if len(sys.argv) > 1 else "https://proof.ovh.net/files/10Mb.dat"
WAIT_SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 90

KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_KEYUP = 0x0002
INPUT_KEYBOARD = 1


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", ctypes.c_ushort),
        ("wScan", ctypes.c_ushort),
        ("dwFlags", ctypes.c_uint),
        ("time", ctypes.c_uint),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.c_long), ("dy", ctypes.c_long),
        ("mouseData", ctypes.c_uint), ("dwFlags", ctypes.c_uint),
        ("time", ctypes.c_uint),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", ctypes.c_uint), ("wParamL", ctypes.c_ushort),
                ("wParamH", ctypes.c_ushort)]


class INPUTUNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", MOUSEINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", ctypes.c_uint), ("u", INPUTUNION)]


SW_RESTORE = 9
VK_MENU = 0x12

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.FindWindowW.restype = ctypes.c_void_p
user32.FindWindowW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]
user32.SetForegroundWindow.restype = ctypes.c_bool
user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
user32.GetForegroundWindow.restype = ctypes.c_void_p
user32.ShowWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
user32.SendInput.restype = ctypes.c_uint
user32.SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(INPUT), ctypes.c_int]


def focus_window(hwnd, timeout=8.0):
    """Pencereyi one getirir ve gercekten one geldigini dogrular.

    SetForegroundWindow, cagiran surec zaten on planda degilse Windows
    tarafindan sessizce reddedilir. Bu yuzden ALT tusu ile kilit acilir ve
    sonuc GetForegroundWindow ile teyit edilir."""
    user32.ShowWindow(hwnd, SW_RESTORE)
    time.sleep(0.3)

    deadline = time.time() + timeout
    while time.time() < deadline:
        if user32.GetForegroundWindow() == hwnd:
            return True
        user32.keybd_event(VK_MENU, 0, 0, 0)
        user32.SetForegroundWindow(hwnd)
        user32.keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0)
        time.sleep(0.4)
    return user32.GetForegroundWindow() == hwnd


def make_key(scan, flags):
    item = INPUT()
    item.type = INPUT_KEYBOARD
    item.ki.wVk = 0
    item.ki.wScan = scan
    item.ki.dwFlags = flags
    return item


def type_text(text):
    inputs = []
    for ch in text:
        inputs.append(make_key(ord(ch), KEYEVENTF_UNICODE))
        inputs.append(make_key(ord(ch), KEYEVENTF_UNICODE | KEYEVENTF_KEYUP))
    arr = (INPUT * len(inputs))(*inputs)
    sent = user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT))
    if sent != len(inputs):
        print("uyari: SendInput %d/%d gonderdi" % (sent, len(inputs)))


def press_enter():
    VK_RETURN = 0x0D
    user32.keybd_event(VK_RETURN, 0, 0, 0)
    time.sleep(0.05)
    user32.keybd_event(VK_RETURN, 0, KEYEVENTF_KEYUP, 0)


os.makedirs(os.path.dirname(SHOT), exist_ok=True)

# Indirme klasorunde ayni dosya varsa temizle
downloads = os.path.join(os.path.expanduser("~"), "Downloads")
target = os.path.join(downloads, URL.rsplit("/", 1)[-1])
for candidate in (target, target + ".serene-merge"):
    if os.path.exists(candidate):
        os.remove(candidate)

proc = subprocess.Popen([EXE], cwd=CWD)

hwnd = None
for _ in range(40):
    time.sleep(0.5)
    if proc.poll() is not None:
        print("erken cikis, kod =", hex(proc.returncode & 0xFFFFFFFF))
        sys.exit(1)
    hwnd = user32.FindWindowW(None, "Serene")
    if hwnd:
        break

if not hwnd:
    print("pencere yok")
    proc.terminate()
    sys.exit(2)

if not focus_window(hwnd):
    print("pencere one getirilemedi; tus vuruslari baska pencereye giderdi")
    print("bu testi kullanmak yerine: node scripts/e2e_cdp.mjs \"%s\"" % URL)
    proc.terminate()
    sys.exit(5)
time.sleep(1.0)

print("URL yaziliyor:", URL)
type_text(URL)
time.sleep(0.5)
press_enter()

ok = False
deadline = time.time() + WAIT_SECONDS
while time.time() < deadline:
    time.sleep(2)
    if proc.poll() is not None:
        print("uygulama coktu, kod =", hex(proc.returncode & 0xFFFFFFFF))
        sys.exit(3)
    if os.path.exists(target):
        time.sleep(3)
        if os.path.exists(target):
            ok = True
            break

time.sleep(2)
ImageGrab.grab().save(SHOT)

proc.terminate()
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()

if ok:
    size = os.path.getsize(target)
    print("BASARILI: %s (%d bayt)" % (target, size))
else:
    print("ZAMAN ASIMI: dosya inmedi", SHOT)
    sys.exit(4)
