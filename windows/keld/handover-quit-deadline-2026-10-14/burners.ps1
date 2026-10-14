param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'stop', 'status')][string]$Action,
    [int]$Count = [Environment]::ProcessorCount
)
# Full-core load for the D measurement's load subset (the KEL-270 F55 method): one
# busy-loop PowerShell process per logical core, tracked by PID in burners.pids.
$ErrorActionPreference = 'Stop'
$evidence = '<evidence-dir>'
$pidFile = Join-Path $evidence 'samples/burners.pids'
switch ($Action) {
    'start' {
        if (Test-Path -LiteralPath $pidFile) { throw 'burners already started (pid file exists)' }
        $pids = @()
        for ($i = 0; $i -lt $Count; $i += 1) {
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', 'while ($true) { $x = 1 }') -PassThru -WindowStyle Hidden
            $pids += $p.Id
        }
        [IO.File]::WriteAllLines($pidFile, [string[]]$pids)
        Write-Output ('BURNERS_STARTED count=' + $pids.Count + ' logical_cores=' + [Environment]::ProcessorCount + ' pids=' + ($pids -join ','))
    }
    'stop' {
        if (-not (Test-Path -LiteralPath $pidFile)) { throw 'no burners pid file' }
        $stopped = 0
        foreach ($id in Get-Content -LiteralPath $pidFile) {
            try { Stop-Process -Id ([int]$id) -Force -ErrorAction Stop; $stopped += 1 } catch {}
        }
        Remove-Item -LiteralPath $pidFile -Force
        Write-Output ('BURNERS_STOPPED stopped=' + $stopped)
    }
    'status' {
        $alive = 0
        if (Test-Path -LiteralPath $pidFile) {
            foreach ($id in Get-Content -LiteralPath $pidFile) { if (Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue) { $alive += 1 } }
        }
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        Write-Output ('BURNERS_STATUS alive=' + $alive + ' cpu_load_percent=' + $cpu)
    }
}
