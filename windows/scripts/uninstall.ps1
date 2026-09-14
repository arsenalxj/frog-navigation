param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\Frog'),
    [switch]$NoShortcuts
)
$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
if ([IO.Path]::GetFileName($target) -ne 'Frog' -or $target -eq [IO.Path]::GetPathRoot($target).TrimEnd('\')) { throw '卸载目录必须是有效的 Frog 安装目录。' }
if (-not (Test-Path -LiteralPath $target)) { Write-Output '青蛙导航尚未安装。'; return }
if ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '拒绝卸载符号链接或目录联接。' }
$marker = Join-Path $target '.frog-install.json'
if (-not (Test-Path -LiteralPath $marker)) { throw '缺少安装标记，已停止卸载。' }
$identity = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
if ($identity.application -ne 'Frog' -or $identity.installDirectory -ne $target) { throw '安装标记不匹配，已停止卸载。' }
$executable = Join-Path $target 'Frog.exe'
$running = Get-CimInstance Win32_Process -Filter "Name='Frog.exe'" | Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -eq $executable }
if ($running) { throw '请先在青蛙导航托盘菜单中退出应用，再卸载。' }
if (-not $NoShortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    $programs = [Environment]::GetFolderPath('Programs')
    $startup = [Environment]::GetFolderPath('Startup')
    foreach ($link in @((Join-Path $programs '青蛙导航.lnk'), (Join-Path $startup 'Frog.lnk'))) {
        if (Test-Path -LiteralPath $link) {
            $shortcut = $shell.CreateShortcut($link)
            if ($shortcut.TargetPath -eq $executable) { Remove-Item -LiteralPath $link -Force }
        }
    }
    $uninstallLink = Join-Path $programs '卸载青蛙导航.lnk'
    if (Test-Path -LiteralPath $uninstallLink) {
        $shortcut = $shell.CreateShortcut($uninstallLink)
        if ($shortcut.Arguments.Contains('"' + (Join-Path $target 'uninstall.ps1') + '"')) { Remove-Item -LiteralPath $uninstallLink -Force }
    }
}
# 只删除已核验的安装目录；书签和自选同步目录始终保留。
Remove-Item -LiteralPath $target -Recurse -Force
Write-Output '已卸载青蛙导航，书签、偏好与图标缓存已保留。'
