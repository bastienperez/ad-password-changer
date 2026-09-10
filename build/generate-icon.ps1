<#
Generates icon.ico (the AD Password Changer padlock from clidsys.com/tools.html,
source SVG kept alongside as source-icon.svg) used by build.ps1 for the compiled exe.
Rerun this script and commit icon.ico if you want to change the icon.
#>

Add-Type -AssemblyName System.Drawing

function New-LockBitmap {
    param([int]$Size)

    # Coordinates below are lifted straight from source-icon.svg's 64x64
    # viewBox and scaled by $s, so this raster icon matches the clidsys.com
    # tools page artwork (body/shackle/keyhole colors included).
    $s = $Size / 64.0

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $bodyColor = [System.Drawing.Color]::FromArgb(255, 0x00, 0x35, 0x3F)
    $shackleColor = [System.Drawing.Color]::FromArgb(255, 0xDE, 0x76, 0x1D)
    $white = [System.Drawing.Color]::White

    # Shackle: <path d="M22 27v-7a10 10 0 0 1 20 0v7" stroke="#de761d" stroke-width="5" stroke-linecap="round"/>
    $penWidth = [Math]::Max(1.5, 5 * $s)
    $pen = New-Object System.Drawing.Pen $shackleColor, $penWidth
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($pen, 22 * $s, 27 * $s, 22 * $s, 20 * $s)
    $g.DrawArc($pen, 22 * $s, 10 * $s, 20 * $s, 20 * $s, 180, 180)
    $g.DrawLine($pen, 42 * $s, 20 * $s, 42 * $s, 27 * $s)

    # Body: <rect x="12" y="27" width="40" height="28" rx="5" fill="#00353f"/>
    $bodyX = 12 * $s; $bodyY = 27 * $s; $bodyWidth = 40 * $s; $bodyHeight = 28 * $s
    $radius = 5 * $s
    $d = $radius * 2

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($bodyX, $bodyY, $d, $d, 180, 90)
    $path.AddArc($bodyX + $bodyWidth - $d, $bodyY, $d, $d, 270, 90)
    $path.AddArc($bodyX + $bodyWidth - $d, $bodyY + $bodyHeight - $d, $d, $d, 0, 90)
    $path.AddArc($bodyX, $bodyY + $bodyHeight - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    $bodyBrush = New-Object System.Drawing.SolidBrush $bodyColor
    $g.FillPath($bodyBrush, $path)

    # Subtle light outline so the dark teal body stays visible on a dark
    # taskbar/background, where it otherwise blends into black.
    $outlineColor = [System.Drawing.Color]::FromArgb(160, 255, 255, 255)
    $outlineWidth = [Math]::Max(0.75, 1.2 * $s)
    $outlinePen = New-Object System.Drawing.Pen -ArgumentList $outlineColor, $outlineWidth
    $outlinePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($outlinePen, $path)

    # Keyhole: <circle cx="32" cy="38" r="4.5" fill="#fff"/> + <rect x="30" y="40" width="4" height="9" rx="2" fill="#fff"/>
    $keyBrush = New-Object System.Drawing.SolidBrush $white
    $keyR = 4.5 * $s
    $g.FillEllipse($keyBrush, 32 * $s - $keyR, 38 * $s - $keyR, $keyR * 2, $keyR * 2)

    $keyRectW = 4 * $s
    $keyRectH = 9 * $s
    $keyRectRadius = [Math]::Min(2 * $s, $keyRectW / 2)
    $keyRectD = $keyRectRadius * 2
    $keyRectX = 30 * $s
    $keyRectY = 40 * $s

    $keyPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $keyPath.AddArc($keyRectX, $keyRectY, $keyRectD, $keyRectD, 180, 90)
    $keyPath.AddArc($keyRectX + $keyRectW - $keyRectD, $keyRectY, $keyRectD, $keyRectD, 270, 90)
    $keyPath.AddArc($keyRectX + $keyRectW - $keyRectD, $keyRectY + $keyRectH - $keyRectD, $keyRectD, $keyRectD, 0, 90)
    $keyPath.AddArc($keyRectX, $keyRectY + $keyRectH - $keyRectD, $keyRectD, $keyRectD, 90, 90)
    $keyPath.CloseFigure()
    $g.FillPath($keyBrush, $keyPath)

    $g.Dispose()
    return $bmp
}

function Save-IconFile {
    param([System.Drawing.Bitmap[]]$Bitmaps, [string]$Path)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms

    $bw.Write([UInt16]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]$Bitmaps.Count)

    $imageData = @()
    foreach ($bmp in $Bitmaps) {
        $pngStream = New-Object System.IO.MemoryStream
        $bmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
        $imageData += , $pngStream.ToArray()
        $pngStream.Dispose()
    }

    $offset = 6 + 16 * $Bitmaps.Count
    for ($i = 0; $i -lt $Bitmaps.Count; $i++) {
        $bmp = $Bitmaps[$i]
        $wByte = if ($bmp.Width -ge 256) { 0 } else { $bmp.Width }
        $hByte = if ($bmp.Height -ge 256) { 0 } else { $bmp.Height }
        $bw.Write([byte]$wByte)
        $bw.Write([byte]$hByte)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]32)
        $bw.Write([UInt32]$imageData[$i].Length)
        $bw.Write([UInt32]$offset)
        $offset += $imageData[$i].Length
    }

    foreach ($data in $imageData) {
        $bw.Write($data)
    }

    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose()
    $ms.Dispose()
}

$root = $PSScriptRoot
$sizes = 16, 32, 48, 256
$bitmaps = $sizes | ForEach-Object { New-LockBitmap -Size $_ }

Save-IconFile -Bitmaps $bitmaps -Path (Join-Path $root 'icon.ico')

foreach ($bmp in $bitmaps) { $bmp.Dispose() }

Write-Output "Icon generated: $(Join-Path $root 'icon.ico')"
