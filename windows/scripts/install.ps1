param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\Frog'),
    [switch]$NoShortcuts
)
$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
if ([IO.Path]::GetFileName($target) -ne 'Frog') { throw '安装目录末级名称必须为 Frog。' }
if ($target -eq [IO.Path]::GetPathRoot($target).TrimEnd('\')) { throw '不能安装到磁盘根目录。' }
$source = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if ($source -eq $target) { throw '请从解压后的新版本目录运行安装脚本。' }
$executable = Join-Path $source 'Frog.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw '请从完整 Release ZIP 解压目录运行安装脚本。' }
$installedExe = Join-Path $target 'Frog.exe'
# 仅识别旧版中文可执行名，新的安装内容统一使用 ASCII 文件名。
$legacyExe = Join-Path $target '青蛙导航.exe'
$running = Get-CimInstance Win32_Process -Filter "Name='青蛙导航.exe' OR Name='Frog.exe'" | Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -in @($installedExe, $legacyExe) }
if ($running) { throw '请先在青蛙导航托盘菜单中退出应用，再运行更新。' }
$marker = Join-Path $target '.frog-install.json'
if (Test-Path -LiteralPath $target) {
    if ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '安装目录不能是符号链接或目录联接。' }
    if (-not (Test-Path -LiteralPath $marker)) { throw '目标目录缺少 Frog 安装标记，请另选位置，避免覆盖已有文件。' }
    $identity = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if ($identity.application -ne 'Frog' -or $identity.installDirectory -ne $target) { throw '安装标记与目标目录不一致。' }
}
$parent = Split-Path $target
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$stage = Join-Path $parent ('Frog-stage-' + [Guid]::NewGuid().ToString('N'))
$backup = Join-Path $parent ('Frog-rollback-' + [Guid]::NewGuid().ToString('N'))
# 所有移动和清理目标均为安装目录同级、本次生成的绝对路径。
foreach ($path in @($stage, $backup)) { if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -ne $parent) { throw '临时目录超出安装父目录。' } }
$hadPrevious = Test-Path -LiteralPath $target
$replaced = $false
# 保存本次实际变更的快捷方式，失败时连同程序一并恢复。
$linkSnapshots = @{}
function Save-LinkSnapshot([string]$Path) {
    if (-not $linkSnapshots.ContainsKey($Path)) {
        $linkSnapshots[$Path] = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllBytes($Path) } else { $null }
    }
}
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($name in @('Frog.exe','install.ps1','uninstall.ps1','README.md','VALIDATION.md','THIRD_PARTY_NOTICES.md')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $stage $name)
        if ((Get-FileHash -LiteralPath (Join-Path $source $name)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $stage $name)).Hash) { throw "文件校验失败：$name" }
    }
    [ordered]@{application='Frog'; installDirectory=$target; version='1.0.0'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage '.frog-install.json') -Encoding UTF8
    if ($hadPrevious) { Move-Item -LiteralPath $target -Destination $backup }
    Move-Item -LiteralPath $stage -Destination $target
    $replaced = $true
    if (-not $NoShortcuts) {
        $shell = New-Object -ComObject WScript.Shell
        $programs = [Environment]::GetFolderPath('Programs')
        Save-LinkSnapshot (Join-Path $programs '青蛙导航.lnk')
        $shortcut = $shell.CreateShortcut((Join-Path $programs '青蛙导航.lnk'))
        $shortcut.TargetPath = $installedExe; $shortcut.WorkingDirectory = $target; $shortcut.IconLocation = "$installedExe,0"; $shortcut.Description = '青蛙导航书签启动台'; $shortcut.Save()
        Save-LinkSnapshot (Join-Path $programs '卸载青蛙导航.lnk')
        $uninstall = $shell.CreateShortcut((Join-Path $programs '卸载青蛙导航.lnk'))
        $uninstall.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $uninstall.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $target 'uninstall.ps1') + '" -InstallDirectory "' + $target + '"'
        $uninstall.WorkingDirectory = $target; $uninstall.Save()
        $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Frog.lnk'
        if (Test-Path -LiteralPath $startupLink) {
            $login = $shell.CreateShortcut($startupLink)
            if ($login.TargetPath -in @($legacyExe, $installedExe) -and $login.Arguments -eq '--background') {
                Save-LinkSnapshot $startupLink
                $login.TargetPath = $installedExe; $login.IconLocation = "$installedExe,0"
                $login.WorkingDirectory = $target; $login.Description = '青蛙导航书签启动台'; $login.Save()
            }
        }
        $oldStart = Join-Path $programs 'Frog.lnk'
        if ((Test-Path -LiteralPath $oldStart) -and $shell.CreateShortcut($oldStart).TargetPath -in @($legacyExe, $installedExe)) {
            Save-LinkSnapshot $oldStart
            Remove-Item -LiteralPath $oldStart -Force
        }
        $oldUninstall = Join-Path $programs '卸载 Frog.lnk'
        if ((Test-Path -LiteralPath $oldUninstall) -and $shell.CreateShortcut($oldUninstall).Arguments.Contains('"' + (Join-Path $target 'uninstall.ps1') + '"')) {
            Save-LinkSnapshot $oldUninstall
            Remove-Item -LiteralPath $oldUninstall -Force
        }
    }
    if ($hadPrevious) {
        try { Remove-Item -LiteralPath $backup -Recurse -Force }
        catch { Write-Warning "安装已完成，旧程序目录暂时无法清理：$backup" }
    }
    Write-Output "已安装到 $target。用户书签、偏好和登录启动状态已保留。"
} catch {
    foreach ($linkPath in $linkSnapshots.Keys) {
        try {
            if ($null -eq $linkSnapshots[$linkPath]) { Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue }
            else { [IO.File]::WriteAllBytes($linkPath, [byte[]]$linkSnapshots[$linkPath]) }
        } catch { Write-Warning "无法恢复快捷方式，请在程序回滚后检查：$linkPath" }
    }
    if ($replaced -and (Test-Path -LiteralPath $target)) { Remove-Item -LiteralPath $target -Recurse -Force }
    if ($hadPrevious -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $target }
    throw
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
