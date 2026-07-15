# Renders res://boot_splash.png -- the thermal-HUD boot splash, in the game font (Inversionz Unboxed).
# The version line is computed from BUILD_PUSHES in scripts/main.gd (v0.19 base + 0.01/push), so just
# re-run this after bumping the build to refresh the stamp:  powershell -File tools/render_boot_splash.ps1
Add-Type -AssemblyName System.Drawing
$repo = Split-Path $PSScriptRoot -Parent
$fontPath = Join-Path $repo "fonts\inversionz_unboxed.ttf"
$out = Join-Path $repo "boot_splash.png"

# --- version from BUILD_PUSHES (matches main.gd _build_version_stamp) ---
$mainGd = Get-Content (Join-Path $repo "scripts\main.gd") -Raw
$pushes = [int]([regex]::Match($mainGd, 'const BUILD_PUSHES: int = (\d+)').Groups[1].Value)
$vh = 19 + $pushes
# integer division like GDScript (truncate) -- PowerShell's [int] would ROUND (1.79 -> 2)
$version = "V{0}.{1:D2}" -f [int][math]::Floor($vh / 100), ($vh % 100)

$W = 1024; $H = 576
$pfc = New-Object System.Drawing.Text.PrivateFontCollection
$pfc.AddFontFile($fontPath)
$fam = $pfc.Families[0]

$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = 'AntiAliasGridFit'
$g.Clear([System.Drawing.Color]::FromArgb(255, 7, 9, 8))

$bright = [System.Drawing.Color]::FromArgb(255, 88, 214, 100)
$dim    = [System.Drawing.Color]::FromArgb(255, 58, 116, 68)
$brushBright = New-Object System.Drawing.SolidBrush $bright
$brushDim    = New-Object System.Drawing.SolidBrush $dim
$penBright = New-Object System.Drawing.Pen $bright, 4.0
$penRet    = New-Object System.Drawing.Pen $dim, 2.0

# corner brackets (frame corners)
$m = 38; $len = 58
$g.DrawLine($penBright, $m, $m, ($m + $len), $m); $g.DrawLine($penBright, $m, $m, $m, ($m + $len))
$g.DrawLine($penBright, ($W - $m), $m, ($W - $m - $len), $m); $g.DrawLine($penBright, ($W - $m), $m, ($W - $m), ($m + $len))
$g.DrawLine($penBright, $m, ($H - $m), ($m + $len), ($H - $m)); $g.DrawLine($penBright, $m, ($H - $m), $m, ($H - $m - $len))
$g.DrawLine($penBright, ($W - $m), ($H - $m), ($W - $m - $len), ($H - $m)); $g.DrawLine($penBright, ($W - $m), ($H - $m), ($W - $m), ($H - $m - $len))

# reticle (centred with the text, lowered toward frame-centre)
$cx = 512; $cy = 285; $R = 128
$g.DrawEllipse($penRet, ($cx - $R), ($cy - $R), (2 * $R), (2 * $R))
$gap = 16; $ext = 20
$g.DrawLine($penRet, $cx, ($cy - $R - $ext), $cx, ($cy - $gap)); $g.DrawLine($penRet, $cx, ($cy + $gap), $cx, ($cy + $R + $ext))
$g.DrawLine($penRet, ($cx - $R - $ext), $cy, ($cx - $gap), $cy); $g.DrawLine($penRet, ($cx + $gap), $cy, ($cx + $R + $ext), $cy)

function Draw-Spaced($text, $sizePx, $brush, $centreY, $tracking, $wordGap) {
    $font = New-Object System.Drawing.Font $fam, $sizePx, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
    $chars = $text.ToCharArray()
    $sf = [System.Drawing.StringFormat]::GenericTypographic
    $ws = @(); $total = 0.0
    foreach ($c in $chars) {
        $wd = $g.MeasureString([string]$c, $font, [System.Drawing.PointF]::new(0,0), $sf).Width
        if ($c -eq ' ') { $wd = $wordGap }
        $ws += $wd; $total += $wd + $tracking
    }
    $total -= $tracking
    $x = ($W - $total) / 2.0
    $y = $centreY - $font.GetHeight($g) / 2.0
    for ($i = 0; $i -lt $chars.Length; $i++) {
        if ($chars[$i] -ne ' ') { $g.DrawString([string]$chars[$i], $font, $brush, $x, $y, $sf) }
        $x += $ws[$i] + $tracking
    }
    $font.Dispose()
}

Draw-Spaced "SPECTRE PROTOCOL" 52 $brushBright 276 10 30
Draw-Spaced "AC-130 GUNSHIP THERMAL ISR" 19 $brushDim 336 6 18
Draw-Spaced $version 19 $brushDim 372 7 14

$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"rendered $out  (version $version)"
