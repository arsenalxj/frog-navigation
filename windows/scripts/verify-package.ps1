param([string]$Package = (Join-Path $PSScriptRoot '..\dist\Frog-windows-x64.zip'))
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$verificationRoot = Join-Path $project 'build\verification'
New-Item -ItemType Directory -Force -Path $verificationRoot | Out-Null
$workspace = Join-Path $verificationRoot ('package-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace | Out-Null
$resolved = [IO.Path]::GetFullPath($workspace)
if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($verificationRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw '验证目录超出 build/verification。' }
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Package))
    try {
        if ([IO.Path]::GetFileName($Package) -match '[^\x00-\x7F]') { throw '安装包文件名必须只含 ASCII 字符。' }
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -match '[^\x00-\x7F]') { throw "ZIP 内文件或目录名包含非 ASCII 字符：$($entry.FullName)" }
        }
    } finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $Package -DestinationPath (Join-Path $workspace 'unpacked')
    $source = Join-Path $workspace 'unpacked\Frog'
    $originalExe = Join-Path $project 'build\Release\Frog.exe'
    if ((Get-FileHash -LiteralPath $originalExe).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source 'Frog.exe')).Hash) { throw 'ZIP 内可执行文件与 Release 不一致。' }
    $target = Join-Path $workspace 'installed\Frog'
    $sentinel = Join-Path $workspace 'user-data\bookmarks.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $sentinel) | Out-Null
    '{"user":"保留的用户数据"}' | Set-Content -LiteralPath $sentinel -Encoding UTF8
    $original = (Get-FileHash -LiteralPath $sentinel).Hash
    & (Join-Path $source 'install.ps1') -InstallDirectory $target -NoShortcuts
    if (-not (Test-Path -LiteralPath (Join-Path $target '.frog-install.json'))) { throw '首次安装标记缺失。' }
    & (Join-Path $source 'install.ps1') -InstallDirectory $target -NoShortcuts
    if ((Get-FileHash -LiteralPath (Join-Path $target 'Frog.exe')).Hash -ne (Get-FileHash -LiteralPath $originalExe).Hash) { throw '更新后文件不一致。' }
    Rename-Item -LiteralPath (Join-Path $target 'Frog.exe') -NewName '青蛙导航.exe'
    & (Join-Path $source 'install.ps1') -InstallDirectory $target -NoShortcuts
    if ((Test-Path -LiteralPath (Join-Path $target '青蛙导航.exe')) -or (Get-FileHash -LiteralPath (Join-Path $target 'Frog.exe')).Hash -ne (Get-FileHash -LiteralPath $originalExe).Hash) { throw '旧版可执行文件改名升级失败。' }
    $badTarget = Join-Path $workspace 'unknown\Frog'
    New-Item -ItemType Directory -Force -Path $badTarget | Out-Null
    '保留' | Set-Content -LiteralPath (Join-Path $badTarget 'keep.txt') -Encoding UTF8
    $rejected = $false
    try { & (Join-Path $source 'install.ps1') -InstallDirectory $badTarget -NoShortcuts } catch { $rejected = $true }
    if (-not $rejected -or -not (Test-Path -LiteralPath (Join-Path $badTarget 'keep.txt'))) { throw '未知安装目录保护失败。' }
    & (Join-Path $source 'uninstall.ps1') -InstallDirectory $target -NoShortcuts
    if (Test-Path -LiteralPath $target) { throw '卸载后程序目录仍存在。' }
    if ((Get-FileHash -LiteralPath $sentinel).Hash -ne $original) { throw '隔离用户数据发生变化。' }
    [ordered]@{date=(Get-Date).ToString('o'); package=[IO.Path]::GetFullPath($Package); zipSha256=(Get-FileHash -LiteralPath $Package).Hash; exeSha256=(Get-FileHash -LiteralPath $originalExe).Hash; asciiArtifactNames=$true; firstInstall=$true; update=$true; legacyNameUpgrade=$true; unknownDirectoryProtected=$true; uninstall=$true; userDataPreserved=$true} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $verificationRoot 'package-report.json') -Encoding UTF8
    Write-Output 'ZIP 解包校验、首次安装、更新、未知目录保护、卸载与数据保留检查全部通过。'
} finally {
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
