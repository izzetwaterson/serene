"""Serene'yi baslatir, pencerenin acildigini dogrular, ekran goruntusu alir
ve sureci kapatir."""

import ctypes
import os
import subprocess
import sys
import time

from PIL import ImageGrab

EXE = r"C:\Users\ornek\Desktop\serene\src-tauri\target\debug\serene.exe"
CWD = r"C:\Users\ornek\Desktop\serene\src-tauri"
SHOT = r"C:\Users\ornek\Desktop\serene\artifacts\serene-window.png"

os.makedirs(os.path.dirname(SHOT), exist_ok=True)

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.FindWindowW.restype = ctypes.c_void_p
user32.FindWindowW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]

proc = subprocess.Popen([EXE], cwd=CWD)

hwnd = None
for _ in range(40):
    time.sleep(0.5)
    if proc.poll() is not None:
        print("EXITED early, code =", hex(proc.returncode & 0xFFFFFFFF))
        sys.exit(1)
    hwnd = user32.FindWindowW(None, "Serene")
    if hwnd:
        break

if not hwnd:
    print("PENCERE BULUNAMADI (surec calisiyor ama pencere yok)")
    proc.terminate()
    sys.exit(2)

print("pencere bulundu, hwnd =", hex(hwnd))

user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
user32.ShowWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
user32.ShowWindow(hwnd, 9)  # SW_RESTORE
user32.SetForegroundWindow(hwnd)
time.sleep(3.0)

ImageGrab.grab().save(SHOT)
print("ekran goruntusu:", SHOT)

proc.terminate()
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
print("kapatildi, cikis kodu =", hex(proc.returncode & 0xFFFFFFFF))
