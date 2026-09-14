param([string]$Destination = (Join-Path $PSScriptRoot '..\resources\AppIcon.ico'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Image]::FromFile([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\assets\frog-navigation.png')))
$frames = @()
try {
    if ($source.Width -ne $source.Height) { throw '图标源图必须为正方形。' }
    foreach ($size in @(16, 24, 32, 48, 64, 128, 256)) {
        $bitmap = New-Object System.Drawing.Bitmap($size, $size)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $stream = New-Object System.IO.MemoryStream
        try {
            $graphics.InterpolationMode = 'HighQualityBicubic'
            $graphics.PixelOffsetMode = 'HighQuality'
            $graphics.Clear([System.Drawing.Color]::White)
            $graphics.DrawImage($source, (New-Object System.Drawing.Rectangle(0, 0, $size, $size)))
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $frames += ,@($size, $stream.ToArray())
        } finally { $stream.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { $source.Dispose() }
$file = [System.IO.File]::Create([System.IO.Path]::GetFullPath($Destination))
$writer = New-Object System.IO.BinaryWriter($file)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($frame in $frames) {
        $side = if ($frame[0] -eq 256) { 0 } else { $frame[0] }
        $writer.Write([byte]$side); $writer.Write([byte]$side); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$frame[1].Length); $writer.Write([uint32]$offset)
        $offset += $frame[1].Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame[1]) }
} finally { $writer.Dispose(); $file.Dispose() }
