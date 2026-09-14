param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\build\Release\Frog.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build\performance'),
    [int]$Count = 1000
)
$ErrorActionPreference = 'Stop'
$Executable = [IO.Path]::GetFullPath($Executable)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$run = Join-Path $OutputDirectory (Get-Date -Format 'yyyyMMdd-HHmmss')
$data = Join-Path $run 'data'
New-Item -ItemType Directory -Force -Path $data | Out-Null
$bookmarks = for ($i = 0; $i -lt $Count; $i++) {
    [ordered]@{id=[Guid]::NewGuid().ToString().ToUpperInvariant(); title=('本地书签 {0:D4}' -f $i); url="https://example.com/$i"; groupId=$null; order=$i; createdAt=1756000000000}
}
$fixture = [ordered]@{format='frog-bookmarks'; schemaVersion=1; groups=@(); bookmarks=@($bookmarks)}
$fixture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $data 'bookmarks.json') -Encoding UTF8
$log = Join-Path $run 'application.jsonl'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FrogProbe {
    public delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int length);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flag);
    public static IntPtr Find(uint target, string cls) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((window, data) => { uint pid; GetWindowThreadProcessId(window, out pid); var name = new System.Text.StringBuilder(80); GetClassName(window, name, 80); if(pid == target && name.ToString() == cls) {result=window; return false;} return true; }, IntPtr.Zero);
        return result;
    }
}
'@
$arguments = '--offline --data-directory "' + $data + '" --diagnostics "' + $log + '"'
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$process = Start-Process -FilePath $Executable -ArgumentList $arguments -WindowStyle Hidden -PassThru
function Read-Events { if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
function Await-Event([string]$Name, [int]$Minimum = 1) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $events = @(Read-Events | Where-Object { $_.event -eq $Name })
        if ($events.Count -ge $Minimum) { return $events[-1] }
        if ($process.HasExited) { throw '性能采样期间应用提前退出。' }
        Start-Sleep -Milliseconds 20
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "等待 $Name 超时。"
}
try {
    $first = Await-Event 'first_interactive'
    $startup = $stopwatch.Elapsed.TotalMilliseconds
    $window = [FrogProbe]::Find($process.Id, 'FrogLauncher')
    $controller = [FrogProbe]::Find($process.Id, 'FrogController')
    $reopens = @()
    for ($i = 1; $i -le 3; $i++) {
        [void][FrogProbe]::SendMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 200
        [void][FrogProbe]::PostMessage($controller, 0x8002, [IntPtr]::Zero, [IntPtr]::Zero)
        $event = Await-Event 'reopened' $i
        $reopens += $event.durationMs
    }
    [void][FrogProbe]::SendMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Seconds 30
    $process.Refresh()
    $private = $process.PrivateMemorySize64
    $workingSet = $process.WorkingSet64
    $cpuBefore = $process.TotalProcessorTime.TotalMilliseconds
    $sample = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 10
    $process.Refresh()
    $cpu = ($process.TotalProcessorTime.TotalMilliseconds - $cpuBefore) / $sample.Elapsed.TotalMilliseconds * 100
    $gpu = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "pid_$($process.Id)_*" } | Select-Object Name,DedicatedUsage,SharedUsage)
    $report = [ordered]@{
        date=(Get-Date).ToString('o'); executable=$Executable; sha256=(Get-FileHash -LiteralPath $Executable).Hash; count=$Count; offline=$true
        os=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture)
        cpu=(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
        ramBytes=(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        graphics=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion)
        processStartToInteractiveMs=$startup; internalFirstPaintMs=$first.durationMs; reopenMs=$reopens
        hiddenPrivateBytes=$private; hiddenWorkingSetBytes=$workingSet; idleCpuPercent=$cpu
        gdiObjects=[FrogProbe]::GetGuiResources($process.Handle,0); userObjects=[FrogProbe]::GetGuiResources($process.Handle,1); gpuMemory=$gpu
        targets=[ordered]@{startup=$startup -le 1000; reopen=(@($reopens | Where-Object { $_ -gt 150 }).Count -eq 0); privateMemory=$private -le 50000000; idleCpu=$cpu -le 0.5}
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'report.json') -Encoding UTF8
    $report | ConvertTo-Json -Depth 8
} finally {
    if (-not $process.HasExited) {
        $window = [FrogProbe]::Find($process.Id, 'FrogLauncher')
        # 仅向本脚本创建的隔离进程发送退出会话消息，等待存储队列排空。
        $controller = [FrogProbe]::Find($process.Id, 'FrogController')
        [void][FrogProbe]::PostMessage($controller, 0x16, [IntPtr]1, [IntPtr]::Zero)
        if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force }
    }
}
