param(
    [Parameter(Mandatory = $true)][string]$ProcessName,
    [string]$Out = "artifacts\window.png"
)

# Emekli raise_window.ps1 + screenshot.ps1'in yerine gecen tek yardimci:
# pencereyi one alir ve yalnizca o pencerenin kapladigi bolgeyi yakalar.
# Ekran goruntusu masaustunden alinir; pencereyi kapatan baska bir pencere
# varsa goruntu karisir, bu yuzden once one alma denenir.

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Cap {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
if (-not $proc) { Write-Output "BASARISIZ: pencere bulunamadi ($ProcessName)"; exit 1 }

$h = $proc.MainWindowHandle
[void][Win32Cap]::ShowWindow($h, 9)   # SW_RESTORE
[void][Win32Cap]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 400

# One alma denerken basarisiz olabilir: Windows arka plandaki bir surece odak
# degistirmeyi reddeder. O zaman ekranin ayni bolgesinde baska bir pencere
# durur ve `CopyFromScreen` onun icerigini kaydeder. Bu, once denendi (bir
# tasarim araci ustteydi) ve sonuc **yanlis** oldu; o yuzden olcu bastan
# sona denetlenir ve uyusmazsa hata verilir.
$fg = [Win32Cap]::GetForegroundWindow()
if ($fg -ne $h) {
    Write-Output "BASARISIZ: pencere one getirilemedi (baska bir uygulama one gecti; ekran goruntusu yanlis olurdu)"
    exit 1
}

$r = New-Object 'Win32Cap+RECT'
[void][Win32Cap]::GetWindowRect($h, [ref]$r)
$w = $r.Right - $r.Left
$ht = $r.Bottom - $r.Top
if ($w -le 0 -or $ht -le 0) { Write-Output "BASARISIZ: pencere olcusu gecersiz"; exit 1 }

$path = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Out))
$dir = [System.IO.Path]::GetDirectoryName($path)
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$g.Dispose()

# Odak degistiyse bile ustte baska bir pencere (orn. her zaman ustte kalan bir
# araç) ekranin ayni dikdortgenini kaplayabilir. Bu durumda goruntu hedef
# pencereye ait degildir; boyle bir sahte dogrulamayi kesinlikle reddediyoruz.
$fg2 = [Win32Cap]::GetForegroundWindow()
if ($fg2 -ne $h) {
    $bmp.Dispose()
    Write-Output "BASARISIZ: kayit aninda baska bir pencere one gecti; goruntu yanlis olurdu"
    exit 1
}

# Duz renkli bir goruntu (bos pencere, ustunu kapatan pencere) sessizce gecmesin.
$colors = New-Object 'System.Collections.Generic.HashSet[int]'
$stepX = [Math]::Max(1, [int]($w / 16))
$stepY = [Math]::Max(1, [int]($ht / 16))
for ($x = 0; $x -lt $w; $x += $stepX) {
    for ($y = 0; $y -lt $ht; $y += $stepY) {
        [void]$colors.Add($bmp.GetPixel($x, $y).ToArgb())
    }
}

$bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Output ("PNG {0} {1}x{2} renk={3}" -f $path, $w, $ht, $colors.Count)
