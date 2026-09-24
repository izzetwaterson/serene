param(
    [Parameter(Mandatory = $true)][string]$ProcessName,
    [switch]$Restore
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Raise {
    [DllImport("user32.dll")] public static extern IntPtr SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
}
"@

$level = if ($Restore) { [Win32Raise]::HWND_NOTOPMOST } else { [Win32Raise]::HWND_TOPMOST }
$flags = [Win32Raise]::SWP_NOSIZE -bor [Win32Raise]::SWP_NOMOVE -bor [Win32Raise]::SWP_NOACTIVATE -bor [Win32Raise]::SWP_SHOWWINDOW

$found = 0
foreach ($proc in Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
    $hwnd = $proc.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { continue }
    [Win32Raise]::SetWindowPos($hwnd, $level, 0, 0, 0, 0, $flags) | Out-Null
    $found++
    Write-Output ("{0} {1} -> {2}" -f $proc.Id, $hwnd, $(if ($Restore) { 'notopmost' } else { 'topmost' }))
}
if ($found -eq 0) { Write-Error "no window for $ProcessName"; exit 1 }
