# KEL-25 Windows MEM-IDLE diagnostic.
#
# Measures idle RSS of a running `keld dev` hello app, reporting every lane
# SEPARATELY (metrics.v1.json MEM-IDLE oracle: "Keld-owned RSS, engine helpers,
# total coalition/tree, and private dirty reported separately").
#
# Stability is CONDITION-BASED (bounded drift), never a fixed sleep --
# windows/bench/CONTRACT.md item 4 records fixed sleeps as a contract violation
# of the existing harness. See Test-BoundedDrift for the negative control.
#
# Does NOT patch Keld sources. PAINT-OPPORTUNITY is therefore out of scope.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ProjectDir,
  [Parameter(Mandatory = $true)][string]$KeldExe,
  [Parameter(Mandatory = $true)][string]$WindowTitle,
  [int]$Runs = 5,
  [string]$OutFile,
  # Bounded-drift stability: the tree-total working set must stay within
  # $DriftRatio of the window mean across $WindowSize consecutive samples.
  [int]$SampleIntervalMs = 250,
  [int]$WindowSize = 6,
  [double]$DriftRatio = 0.01,
  [int]$MaxStabilityWaitMs = 40000,
  [int]$ReadyTimeoutMs = 60000
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class KeldW32 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@ -ErrorAction SilentlyContinue

function Get-DescendantPids {
  param([int]$RootPid)
  # One CIM snapshot, then walk ParentProcessId edges. Avoids per-process
  # queries racing process exit mid-walk.
  $all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name
  $byParent = @{}
  foreach ($p in $all) {
    $key = [int]$p.ParentProcessId
    if (-not $byParent.ContainsKey($key)) { $byParent[$key] = New-Object System.Collections.ArrayList }
    [void]$byParent[$key].Add($p)
  }
  $result = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue($RootPid)
  $seen = @{}
  while ($queue.Count -gt 0) {
    $cur = [int]$queue.Dequeue()
    if ($seen.ContainsKey($cur)) { continue }
    $seen[$cur] = $true
    if ($byParent.ContainsKey($cur)) {
      foreach ($child in $byParent[$cur]) {
        [void]$result.Add($child)
        $queue.Enqueue([int]$child.ProcessId)
      }
    }
  }
  return $result
}

function Get-TreeSnapshot {
  param([int]$HostPid)
  $hostProc = Get-Process -Id $HostPid -ErrorAction SilentlyContinue
  if (-not $hostProc) { return $null }

  $lanes = [ordered]@{
    host_ws_bytes      = [int64]$hostProc.WorkingSet64
    host_private_bytes = [int64]$hostProc.PrivateMemorySize64
    bun_ws_bytes       = [int64]0
    bun_private_bytes  = [int64]0
    engine_ws_bytes    = [int64]0
    engine_private_bytes = [int64]0
    other_ws_bytes     = [int64]0
    bun_count          = 0
    engine_count       = 0
    other_count        = 0
  }

  foreach ($d in (Get-DescendantPids -RootPid $HostPid)) {
    $dp = Get-Process -Id ([int]$d.ProcessId) -ErrorAction SilentlyContinue
    if (-not $dp) { continue }
    $ws = [int64]$dp.WorkingSet64
    $pv = [int64]$dp.PrivateMemorySize64
    if ($dp.ProcessName -eq 'bun') {
      $lanes.bun_ws_bytes += $ws; $lanes.bun_private_bytes += $pv; $lanes.bun_count++
    } elseif ($dp.ProcessName -eq 'msedgewebview2') {
      $lanes.engine_ws_bytes += $ws; $lanes.engine_private_bytes += $pv; $lanes.engine_count++
    } else {
      $lanes.other_ws_bytes += $ws; $lanes.other_count++
    }
  }
  $lanes.tree_ws_bytes = $lanes.host_ws_bytes + $lanes.bun_ws_bytes + $lanes.engine_ws_bytes + $lanes.other_ws_bytes
  # architecture 01 section 5 scopes the >=90MB budget as "sum of keld processes".
  # Recorded as its own lane; NEVER blended with the engine lane.
  $lanes.keld_processes_ws_bytes = $lanes.host_ws_bytes + $lanes.bun_ws_bytes
  return $lanes
}

function Wait-BoundedDrift {
  <#
    Condition-based stability. Returns a hashtable with Stable/Samples/Reason.
    Stable when the last $WindowSize tree totals have (max-min) <= DriftRatio * mean.
  #>
  param([int]$HostPid)
  $series = New-Object System.Collections.ArrayList
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $MaxStabilityWaitMs) {
    $snap = Get-TreeSnapshot -HostPid $HostPid
    if ($null -eq $snap) { return @{ Stable = $false; Reason = 'PROCESS_EXITED'; Samples = $series; Snapshot = $null } }
    [void]$series.Add($snap)
    if ($series.Count -ge $WindowSize) {
      $window = $series[($series.Count - $WindowSize)..($series.Count - 1)]
      $totals = $window | ForEach-Object { $_.tree_ws_bytes }
      $min = ($totals | Measure-Object -Minimum).Minimum
      $max = ($totals | Measure-Object -Maximum).Maximum
      $mean = ($totals | Measure-Object -Average).Average
      if ($mean -gt 0 -and (($max - $min) / $mean) -le $DriftRatio) {
        return @{ Stable = $true; Reason = $null; Samples = $series; Snapshot = $series[$series.Count - 1];
                  DriftObserved = [math]::Round((($max - $min) / $mean), 6); SettleMs = [int]$sw.ElapsedMilliseconds }
      }
    }
    Start-Sleep -Milliseconds $SampleIntervalMs
  }
  return @{ Stable = $false; Reason = 'STABILITY_TIMEOUT'; Samples = $series; Snapshot = $series[$series.Count - 1] }
}

# --- negative control -------------------------------------------------------
function Test-BoundedDrift {
  # A drifting series MUST NOT be accepted as stable; a flat one MUST be.
  $flat    = @(100, 100, 100, 100, 100, 100)
  $drifting= @(100, 140, 190, 250, 320, 400)
  $check = {
    param($vals, $ratio)
    $min = ($vals | Measure-Object -Minimum).Minimum
    $max = ($vals | Measure-Object -Maximum).Maximum
    $mean = ($vals | Measure-Object -Average).Average
    return ((($max - $min) / $mean) -le $ratio)
  }
  $flatStable = & $check $flat 0.01
  $driftStable = & $check $drifting 0.01
  if (-not $flatStable) { throw "NEGATIVE CONTROL FAILED: a flat series was rejected as unstable" }
  if ($driftStable) { throw "NEGATIVE CONTROL FAILED: a drifting series was accepted as stable" }
  Write-Output "negative-control: flat=accepted drifting=rejected  OK"
}

Test-BoundedDrift

# NOTE: must not be named $runs -- PowerShell variables are case-insensitive,
# so $runs would alias the [int]$Runs parameter and fail the cast.
$runRecords = New-Object System.Collections.ArrayList

for ($i = 1; $i -le $Runs; $i++) {
  Write-Output "--- run $i/$Runs ---"

  $stdout = [System.IO.Path]::GetTempFileName()
  $stderr = [System.IO.Path]::GetTempFileName()
  $proc = Start-Process -FilePath $KeldExe -ArgumentList 'dev' -WorkingDirectory $ProjectDir `
            -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $hostPid = $proc.Id
  $t0 = [System.Diagnostics.Stopwatch]::StartNew()

  # Readiness condition: a real, visible, non-minimized native window with our title.
  $hwnd = [IntPtr]::Zero
  $nativeWindowMs = $null
  while ($t0.ElapsedMilliseconds -lt $ReadyTimeoutMs) {
    $p = Get-Process -Id $hostPid -ErrorAction SilentlyContinue
    if (-not $p) { break }
    $p.Refresh()
    if ($p.MainWindowTitle -eq $WindowTitle -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
      $h = $p.MainWindowHandle
      if ([KeldW32]::IsWindowVisible($h) -and -not [KeldW32]::IsIconic($h)) {
        $hwnd = $h; $nativeWindowMs = [int]$t0.ElapsedMilliseconds; break
      }
    }
    Start-Sleep -Milliseconds 50
  }

  if ($hwnd -eq [IntPtr]::Zero) {
    [void]$runRecords.Add([ordered]@{ run = $i; valid = $false; reject_reason = 'NATIVE_WINDOW_NOT_OBSERVED'; value = $null })
    if (Get-Process -Id $hostPid -ErrorAction SilentlyContinue) { Stop-Process -Id $hostPid -Force }
    continue
  }

  $stab = Wait-BoundedDrift -HostPid $hostPid
  $snap = $stab.Snapshot

  $record = [ordered]@{
    run           = $i
    valid         = [bool]$stab.Stable
    reject_reason = $stab.Reason
    # scored lane per metrics.v1.json: Keld-owned (main) RSS, in KiB
    value         = if ($snap) { [math]::Round($snap.host_ws_bytes / 1024, 1) } else { $null }
    diagnostics   = [ordered]@{
      native_window_ms          = $nativeWindowMs
      settle_ms                 = $stab.SettleMs
      drift_observed            = $stab.DriftObserved
      stability_samples         = $stab.Samples.Count
      host_ws_kib               = if ($snap) { [math]::Round($snap.host_ws_bytes / 1024, 1) } else { $null }
      host_private_kib          = if ($snap) { [math]::Round($snap.host_private_bytes / 1024, 1) } else { $null }
      bun_ws_kib                = if ($snap) { [math]::Round($snap.bun_ws_bytes / 1024, 1) } else { $null }
      bun_private_kib           = if ($snap) { [math]::Round($snap.bun_private_bytes / 1024, 1) } else { $null }
      bun_process_count         = if ($snap) { $snap.bun_count } else { $null }
      engine_ws_kib             = if ($snap) { [math]::Round($snap.engine_ws_bytes / 1024, 1) } else { $null }
      engine_private_kib        = if ($snap) { [math]::Round($snap.engine_private_bytes / 1024, 1) } else { $null }
      engine_process_count      = if ($snap) { $snap.engine_count } else { $null }
      keld_processes_ws_kib     = if ($snap) { [math]::Round($snap.keld_processes_ws_bytes / 1024, 1) } else { $null }
      tree_ws_kib               = if ($snap) { [math]::Round($snap.tree_ws_bytes / 1024, 1) } else { $null }
      counter                   = 'Process.WorkingSet64 (Windows working set; RSS analogue), PrivateMemorySize64 for private'
    }
  }
  [void]$runRecords.Add($record)
  Write-Output ("    host={0} KiB  bun={1} KiB  engine={2} KiB x{3}  tree={4} KiB  stable={5} settle={6}ms" -f `
      $record.diagnostics.host_ws_kib, $record.diagnostics.bun_ws_kib, $record.diagnostics.engine_ws_kib, `
      $record.diagnostics.engine_process_count, $record.diagnostics.tree_ws_kib, $record.valid, $record.diagnostics.settle_ms)

  [void][KeldW32]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
  $exited = $proc.WaitForExit(20000)
  if (-not $exited) { Stop-Process -Id $hostPid -Force }
  Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

  # Fresh-process cache state: require the previous coalition to be gone before
  # the next run. Condition, not a sleep.
  $gone = [System.Diagnostics.Stopwatch]::StartNew()
  while ($gone.ElapsedMilliseconds -lt 15000) {
    if (-not (Get-Process -Id $hostPid -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 100
  }
}

$runRecords | ConvertTo-Json -Depth 8 | Out-String -Width 400 | Write-Output
if ($OutFile) {
  # UTF-8 WITHOUT BOM. PowerShell 5.1 Set-Content -Encoding utf8 emits a BOM,
  # which strict JSON parsers reject (recorded trap in windows/bench/CONTRACT.md).
  $json = $runRecords | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Output "wrote $OutFile"
}
