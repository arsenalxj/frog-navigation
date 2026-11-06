param([string]$Destination = (Join-Path $PSScriptRoot '..\resources\AppIcon.ico'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System.Drawing;
public static class FrogTrayIcon {
    public static Bitmap TransparentBackground(Image source) {
        var image = new Bitmap(source);
        int width = image.Width, height = image.Height;
        var visited = new bool[width * height];
        var queue = new int[visited.Length];
        int read = 0, write = 0;
        System.Action<int, int> add = (x, y) => {
            int index = y * width + x;
            if (visited[index]) return;
            visited[index] = true;
            var color = image.GetPixel(x, y);
            if (color.R < 240 || color.G < 240 || color.B < 240) return;
            queue[write++] = index;
        };
        for (int x = 0; x < width; ++x) { add(x, 0); add(x, height - 1); }
        for (int y = 0; y < height; ++y) { add(0, y); add(width - 1, y); }
        while (read < write) {
            int index = queue[read++], x = index % width, y = index / width;
            image.SetPixel(x, y, Color.Transparent);
            if (x > 0) add(x - 1, y);
            if (x + 1 < width) add(x + 1, y);
            if (y > 0) add(x, y - 1);
            if (y + 1 < height) add(x, y + 1);
        }
        return image;
    }
}
'@ -ReferencedAssemblies System.Drawing
$source = [System.Drawing.Image]::FromFile([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\assets\frog-navigation.png')))
$original = $source
try {
foreach ($tray in @($false, $true)) {
if ($tray) { $source = [FrogTrayIcon]::TransparentBackground($original) }
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
            $graphics.Clear($(if ($tray) { [System.Drawing.Color]::Transparent } else { [System.Drawing.Color]::White }))
            $graphics.DrawImage($source, (New-Object System.Drawing.Rectangle(0, 0, $size, $size)))
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $frames += ,@($size, $stream.ToArray())
        } finally { $stream.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { if ($tray) { $source.Dispose() } }
$output = if ($tray) { Join-Path (Split-Path $Destination) 'TrayIcon.ico' } else { $Destination }
$file = [System.IO.File]::Create([System.IO.Path]::GetFullPath($output))
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
}
} finally { $original.Dispose() }
