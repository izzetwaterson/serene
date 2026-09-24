Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$out = $args[0]
if (-not $out) { $out = 'C:\Users\ornek\Desktop\serene\artifacts\screen.png' }

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bmp)
$graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)

Write-Output ("saved " + $out + " (" + $bounds.Width + "x" + $bounds.Height + ")")
