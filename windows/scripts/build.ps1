param([ValidateSet('Debug','Release')][string]$Configuration = 'Release', [switch]$SkipTests, [switch]$SkipPackage)
$ErrorActionPreference = 'Stop'
$project = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw '请安装 Visual Studio 的「使用 C++ 的桌面开发」工作负载。' }
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw '没有找到 MSVC x64 编译器。' }
$cmake = Join-Path $installation 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$ctest = Join-Path (Split-Path $cmake) 'ctest.exe'
if (-not (Test-Path -LiteralPath $cmake)) { $cmake = (Get-Command cmake -ErrorAction Stop).Source; $ctest = (Get-Command ctest -ErrorAction Stop).Source }
$major = [int](& $vswhere -latest -products '*' -property installationVersion).Split('.')[0]
$generator = if ($major -ge 18) { 'Visual Studio 18 2026' } else { 'Visual Studio 17 2022' }
& (Join-Path $PSScriptRoot 'generate-icon.ps1')
$build = Join-Path $project 'build'
& $cmake -S $project -B $build -G $generator -A x64
if ($LASTEXITCODE -ne 0) { throw 'CMake 配置失败。' }
& $cmake --build $build --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) { throw '编译失败。' }
if (-not $SkipTests) {
    & $ctest --test-dir $build -C $Configuration --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw '测试失败。' }
}
if ($Configuration -eq 'Release' -and -not $SkipPackage) {
    $stage = Join-Path $build 'package\Frog'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -LiteralPath (Join-Path $build 'Release\Frog.exe') -Destination $stage -Force
    foreach ($name in @('install.ps1','uninstall.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $stage -Force }
    foreach ($name in @('README.md','VALIDATION.md','THIRD_PARTY_NOTICES.md')) { Copy-Item -LiteralPath (Join-Path $project $name) -Destination $stage -Force }
    $dist = Join-Path $project 'dist'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Compress-Archive -Path $stage -DestinationPath (Join-Path $dist 'Frog-windows-x64.zip') -Force
    Get-FileHash -LiteralPath (Join-Path $dist 'Frog-windows-x64.zip') -Algorithm SHA256
}
