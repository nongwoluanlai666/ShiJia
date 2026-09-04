param(
    [Parameter(Mandatory = $true)]
    [string]$Output
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$directory = Split-Path -Parent $Output
if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

function New-WorkflowIconPng {
    param([int]$Size)

    $scale = $Size / 64.0
    $bitmap = New-Object Drawing.Bitmap($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $brush = $null
    $pen = $null
    $stream = $null
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.Clear([Drawing.Color]::Transparent)

        $path.AddArc([single](2 * $scale), [single](2 * $scale), [single](20 * $scale), [single](20 * $scale), 180, 90)
        $path.AddArc([single](42 * $scale), [single](2 * $scale), [single](20 * $scale), [single](20 * $scale), 270, 90)
        $path.AddArc([single](42 * $scale), [single](42 * $scale), [single](20 * $scale), [single](20 * $scale), 0, 90)
        $path.AddArc([single](2 * $scale), [single](42 * $scale), [single](20 * $scale), [single](20 * $scale), 90, 90)
        $path.CloseFigure()
        $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 37, 99, 235))
        $graphics.FillPath($brush, $path)

        $lineWidth = [single][Math]::Max(1.0, 2.5 * $scale)
        $pen = New-Object Drawing.Pen([Drawing.Color]::White, $lineWidth)
        $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $graphics.DrawLine($pen, [single](25 * $scale), [single](24 * $scale), [single](39 * $scale), [single](24 * $scale))
        $graphics.DrawLine($pen, [single](39 * $scale), [single](24 * $scale), [single](39 * $scale), [single](40 * $scale))
        $graphics.DrawLine($pen, [single](25 * $scale), [single](40 * $scale), [single](39 * $scale), [single](40 * $scale))
        $pen.Dispose()
        $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255, 45, 212, 191), $lineWidth)
        $graphics.DrawLine($pen, [single](39 * $scale), [single](40 * $scale), [single](48 * $scale), [single](40 * $scale))
        $graphics.DrawLine($pen, [single](44 * $scale), [single](36 * $scale), [single](48 * $scale), [single](40 * $scale))
        $graphics.DrawLine($pen, [single](44 * $scale), [single](44 * $scale), [single](48 * $scale), [single](40 * $scale))

        $brush.Dispose()
        $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 248, 250, 252))
        $graphics.FillRectangle($brush, [single](18 * $scale), [single](18 * $scale), [single](12 * $scale), [single](12 * $scale))
        $graphics.FillRectangle($brush, [single](34 * $scale), [single](34 * $scale), [single](12 * $scale), [single](12 * $scale))
        $graphics.FillRectangle($brush, [single](12 * $scale), [single](34 * $scale), [single](12 * $scale), [single](12 * $scale))
        $brush.Dispose()
        $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 34, 197, 94))
        $graphics.FillEllipse($brush, [single](14 * $scale), [single](20 * $scale), [single](8 * $scale), [single](8 * $scale))
        $brush.Dispose()
        $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 249, 115, 22))
        $graphics.FillEllipse($brush, [single](42 * $scale), [single](36 * $scale), [single](8 * $scale), [single](8 * $scale))
        $brush.Dispose()
        $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 139, 92, 246))
        $graphics.FillEllipse($brush, [single](14 * $scale), [single](36 * $scale), [single](8 * $scale), [single](8 * $scale))

        $stream = New-Object IO.MemoryStream
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $pen) { $pen.Dispose() }
        if ($null -ne $brush) { $brush.Dispose() }
        $path.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$sizes = @(16, 20, 24, 32, 40, 48, 64, 80, 96, 128, 192, 256)
$images = New-Object System.Collections.ArrayList
foreach ($size in $sizes) { [void]$images.Add((New-WorkflowIconPng $size)) }

$outputStream = [IO.File]::Open($Output, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
$writer = New-Object IO.BinaryWriter($outputStream)
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$sizes.Count)
    $imageOffset = 6 + (16 * $sizes.Count)
    for ($index = 0; $index -lt $sizes.Count; $index++) {
        $dimension = if ($sizes[$index] -ge 256) { 0 } else { $sizes[$index] }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$images[$index].Length)
        $writer.Write([uint32]$imageOffset)
        $imageOffset += $images[$index].Length
    }
    foreach ($image in $images) { $writer.Write([byte[]]$image) }
} finally {
    $writer.Dispose()
}
Write-Output "Generated icon: $Output"
