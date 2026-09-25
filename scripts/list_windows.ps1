param(
    [Parameter(Mandatory = $true)][string]$ProcessName
)

# Kosumlarin pencereyi gormek icin kullandigi tek yardimci: her satir
# "pid <TAB> baslik <TAB> gorunur". Flutter Windows kosucusu sentetik
# tiklamalari almadigi icin arayuz denetimi pencereyi yalnizca gozleyebilir.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

foreach ($proc in Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
    $visible = if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { '1' } else { '0' }
    "{0}`t{1}`t{2}" -f $proc.Id, $proc.MainWindowTitle, $visible
}
