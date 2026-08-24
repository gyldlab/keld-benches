# Round-major randomized interleaved multi-arm GUI session (MEM-IDLE class).
#
# WHY
# ---
# Every committed Windows document carries ARMS_NOT_INTERLEAVED and
# NO_PAIRED_ARM. result.v1 session.interleaving is an enum of exactly
# "none" | "round-robin-randomized", and its description says publication
# requires balanced randomized interleaving by round. The existing harnesses
# are arm-major: all runs of one arm, then the next, so any drift over the
# session lands entirely on whichever arm ran later.
#
# This is a LOOP INVERSION, not a rewrite. windows/bench/CONTRACT.md records
# that the existing measurement logic is correct prior art and must not be
# rewritten to satisfy the contract, so the settle rule here is the same one
# Measure-KeldIdleRss.ps1 uses: bounded drift AND a stable process-class
# census with a non-zero engine floor.
#
# DUPLICATION, DELIBERATE. The snapshot/settle helpers below are a copy rather
# than a shared import. Measure-KeldIdleRss.ps1 is cited by sha256 in the
# committed MEM-IDLE and NATIVE-WINDOW documents as the harness that produced
# their raw data; editing it to extract a shared module would falsify that
# provenance. Future harnesses should share from here instead.
#
# NOTHING IS SILENTLY DROPPED. The first scored round of each arm is preceded
# by an explicit WARMUP launch recorded as an unscored sample with reason
# WARMUP_UNSCORED, because Defender real-time protection makes the first touch
# of a fresh binary a large outlier and interleaving RELOCATES that bias onto
# whichever arm draws round 1 rather than removing it.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BenchRepo,
  [Parameter(Mandatory = $true)][string]$KeldExe,
  [int]$Rounds = 30,
  [int]$Seed = 20260824,
  [string]$OutFile,
  [int]$SampleIntervalMs = 250,
  [int]$WindowSize = 6,
  [double]$DriftRatio = 0.01,
  [int]$MaxStabilityWaitMs = 40000,
  [int]$ReadyTimeoutMs = 60000,
  [int]$MinEngineProcesses = 1,
  # Cooling gate. Sixty GUI launches back to back heat this class of laptop
  # past the 1.05 thermal band by the closing boundary (measured: start
  # nominal 1.0025 at 84 C, end throttled 1.0812 at 87 C). Probing every N
  # rounds and idling until nominal keeps the whole session inside the band.
  # The idle interval between probe attempts is a COOLING period, not a
  # stability mechanism: the condition being awaited is the probe verdict,
  # which is what CONTRACT.md item 4 requires instead of a fixed settle.
  [int]$ThermalGateEveryRounds = 5,
  [int]$ThermalGateMaxWaitMs = 900000,
  [int]$ThermalGatePollMs = 60000
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class GuiSessW32 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@ -ErrorAction SilentlyContinue

# --- arm registry ------------------------------------------------------------
# runtime_child is the supervised JS-runtime process an arm owns, or empty when
# the arm runs no application JavaScript at all. Tauri is the latter: its
# backend is Rust and its hello runs a bare tauri::Builder. That asymmetry is
# the whole point of reporting lanes separately rather than one blended total.
$ARMS = @(
  [ordered]@{
    arm_id        = 'keld'
    exe           = $KeldExe
    args          = @('dev')
    workdir       = (Join-Path $BenchRepo 'windows\keld\hello')
    title         = 'hello'
    runtime_child = 'bun'
    framework     = 'Keld host-owned hello (keld dev)'
  }
  [ordered]@{
    arm_id        = 'tauri'
    exe           = (Join-Path $BenchRepo 'windows\tauri\hello\src-tauri\target\release\tauri-hello.exe')
    args          = @()
    workdir       = (Join-Path $BenchRepo 'windows\tauri\hello')
    title         = 'Tauri Hello'
    runtime_child = ''
    framework     = 'Tauri 2 hello'
  }
)

function Get-DescendantProcs {
  param([int]$RootPid)
  $all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name
  $byParent = @{}
  foreach ($p in $all) {
    $k = [int]$p.ParentProcessId
    if (-not $byParent.ContainsKey($k)) { $byParent[$k] = New-Object System.Collections.ArrayList }
    [void]$byParent[$k].Add($p)
  }
  $out = New-Object System.Collections.ArrayList
  $q = New-Object System.Collections.Queue
  $q.Enqueue($RootPid)
  $seen = @{}
  while ($q.Count -gt 0) {
    $cur = [int]$q.Dequeue()
    if ($seen.ContainsKey($cur)) { continue }
    $seen[$cur] = $true
    if ($byParent.ContainsKey($cur)) {
      foreach ($c in $byParent[$cur]) { [void]$out.Add($c); $q.Enqueue([int]$c.ProcessId) }
    }
  }
  return $out
}

function Get-TreeSnapshot {
  param([int]$HostPid, [string]$RuntimeChild)
  $hp = Get-Process -Id $HostPid -ErrorAction SilentlyContinue
  if (-not $hp) { return $null }
  $lanes = [ordered]@{
    host_ws_bytes = [int64]$hp.WorkingSet64; host_private_bytes = [int64]$hp.PrivateMemorySize64
    runtime_ws_bytes = [int64]0; runtime_private_bytes = [int64]0; runtime_count = 0
    engine_ws_bytes = [int64]0; engine_private_bytes = [int64]0; engine_count = 0
    other_ws_bytes = [int64]0; other_count = 0
  }
  foreach ($d in (Get-DescendantProcs -RootPid $HostPid)) {
    $dp = Get-Process -Id ([int]$d.ProcessId) -ErrorAction SilentlyContinue
    if (-not $dp) { continue }
    $ws = [int64]$dp.WorkingSet64; $pv = [int64]$dp.PrivateMemorySize64
    if ($RuntimeChild -and $dp.ProcessName -eq $RuntimeChild) {
      $lanes.runtime_ws_bytes += $ws; $lanes.runtime_private_bytes += $pv; $lanes.runtime_count++
    } elseif ($dp.ProcessName -eq 'msedgewebview2') {
      $lanes.engine_ws_bytes += $ws; $lanes.engine_private_bytes += $pv; $lanes.engine_count++
    } else {
      $lanes.other_ws_bytes += $ws; $lanes.other_count++
    }
  }
  $lanes.tree_ws_bytes = $lanes.host_ws_bytes + $lanes.runtime_ws_bytes + $lanes.engine_ws_bytes + $lanes.other_ws_bytes
  # "sum of keld processes" in architecture 01 section 5 terms: the framework
  # own processes, excluding the shared system engine.
  $lanes.framework_ws_bytes = $lanes.host_ws_bytes + $lanes.runtime_ws_bytes
  $lanes.framework_private_bytes = $lanes.host_private_bytes + $lanes.runtime_private_bytes
  return $lanes
}

function Wait-Settled {
  param([int]$HostPid, [string]$RuntimeChild, [int]$MinRuntime)
  $series = New-Object System.Collections.ArrayList
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $MaxStabilityWaitMs) {
    $snap = Get-TreeSnapshot -HostPid $HostPid -RuntimeChild $RuntimeChild
    if ($null -eq $snap) { return @{ Stable = $false; Reason = 'PROCESS_EXITED'; Snapshot = $null } }
    [void]$series.Add($snap)
    if ($env:KELD_BENCH_DEBUG) {
      # Write-Host, never Write-Output: Write-Output inside a function that
      # returns a value appends to that return value, turning the hashtable
      # into an array and silently breaking every property read on it.
      Write-Host ("      [dbg] rt=$($snap.runtime_count) eng=$($snap.engine_count) oth=$($snap.other_count)")
    }
    if ($series.Count -ge $WindowSize) {
      $w = $series[($series.Count - $WindowSize)..($series.Count - 1)]
      $tot = $w | ForEach-Object { $_.tree_ws_bytes }
      $mn = ($tot | Measure-Object -Minimum).Minimum
      $mx = ($tot | Measure-Object -Maximum).Maximum
      $mean = ($tot | Measure-Object -Average).Average
      $driftOk = ($mean -gt 0 -and (($mx - $mn) / $mean) -le $DriftRatio)
      $census = $w | ForEach-Object { "$($_.runtime_count)/$($_.engine_count)/$($_.other_count)" }
      $memberOk = ((($census | Select-Object -Unique) | Measure-Object).Count -eq 1)
      $last = $series[$series.Count - 1]
      $engineOk = ($last.engine_count -ge $MinEngineProcesses)
      $runtimeOk = $true
      if ($MinRuntime -gt 0) { $runtimeOk = ($last.runtime_count -ge $MinRuntime) }
      if ($driftOk -and $memberOk -and $engineOk -and $runtimeOk) {
        return @{ Stable = $true; Reason = $null; Snapshot = $last
                  Drift = [math]::Round((($mx - $mn) / $mean), 6); SettleMs = [int]$sw.ElapsedMilliseconds }
      }
    }
    Start-Sleep -Milliseconds $SampleIntervalMs
  }
  $last = $null
  if ($series.Count -gt 0) { $last = $series[$series.Count - 1] }
  $reason = 'STABILITY_TIMEOUT'
  if ($null -ne $last -and $last.engine_count -lt $MinEngineProcesses) { $reason = 'MEMBERSHIP_CHURN_ENGINE_ABSENT' }
  if ($null -ne $last -and $MinRuntime -gt 0 -and $last.runtime_count -lt $MinRuntime) { $reason = 'MEMBERSHIP_CHURN_RUNTIME_ABSENT' }
  return @{ Stable = $false; Reason = $reason; Snapshot = $last }
}

function Invoke-ArmRun {
  param($Arm, [int]$RoundNo, [bool]$IsWarmup)
  $proc = $null
  $rec = [ordered]@{
    arm = $Arm.arm_id; round = $RoundNo; warmup = $IsWarmup
    valid = $false; reject_reason = $null; value = $null; diagnostics = $null
  }
  try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Arm.args.Count -gt 0) {
      $proc = Start-Process -FilePath $Arm.exe -ArgumentList $Arm.args -WorkingDirectory $Arm.workdir -PassThru
    } else {
      $proc = Start-Process -FilePath $Arm.exe -WorkingDirectory $Arm.workdir -PassThru
    }
    $hwnd = [IntPtr]::Zero; $windowMs = $null
    while ($sw.ElapsedMilliseconds -lt $ReadyTimeoutMs) {
      if ($proc.HasExited) { break }
      $proc.Refresh()
      if ($proc.MainWindowTitle -eq $Arm.title -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
        $h = $proc.MainWindowHandle
        if ([GuiSessW32]::IsWindowVisible($h) -and -not [GuiSessW32]::IsIconic($h)) {
          $hwnd = $h; $windowMs = [int]$sw.ElapsedMilliseconds; break
        }
      }
      Start-Sleep -Milliseconds 50
    }
    if ($hwnd -eq [IntPtr]::Zero) { $rec.reject_reason = 'NATIVE_WINDOW_NOT_OBSERVED'; return $rec }

    $minRuntime = 0
    if ($Arm.runtime_child) { $minRuntime = 1 }
    $st = Wait-Settled -HostPid $proc.Id -RuntimeChild $Arm.runtime_child -MinRuntime $minRuntime
    $s = $st.Snapshot
    if (-not $st.Stable) { $rec.reject_reason = $st.Reason; return $rec }

    $rec.valid = (-not $IsWarmup)
    if ($IsWarmup) { $rec.reject_reason = 'WARMUP_UNSCORED' }
    $rec.value = [math]::Round($s.host_ws_bytes / 1024, 1)
    $rec.diagnostics = [ordered]@{
      host_ws_kib             = [math]::Round($s.host_ws_bytes / 1024, 1)
      host_private_kib        = [math]::Round($s.host_private_bytes / 1024, 1)
      runtime_ws_kib          = [math]::Round($s.runtime_ws_bytes / 1024, 1)
      runtime_private_kib     = [math]::Round($s.runtime_private_bytes / 1024, 1)
      runtime_process_count   = $s.runtime_count
      engine_ws_kib           = [math]::Round($s.engine_ws_bytes / 1024, 1)
      engine_process_count    = $s.engine_count
      framework_ws_kib        = [math]::Round($s.framework_ws_bytes / 1024, 1)
      framework_private_kib   = [math]::Round($s.framework_private_bytes / 1024, 1)
      tree_ws_kib             = [math]::Round($s.tree_ws_bytes / 1024, 1)
      native_window_ms        = $windowMs
      settle_ms               = $st.SettleMs
      drift_observed          = $st.Drift
      counter                 = 'Process.WorkingSet64 (RSS analogue) and PrivateMemorySize64'
    }
    return $rec
  }
  finally {
    if ($proc -and -not $proc.HasExited) {
      $proc.Refresh()
      if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        [void][GuiSessW32]::PostMessage($proc.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
      }
      if (-not $proc.WaitForExit(20000)) { try { Stop-Process -Id $proc.Id -Force } catch {} }
    }
    # fresh-process class: require the coalition gone before the next launch
    if ($proc) {
      $g = [System.Diagnostics.Stopwatch]::StartNew()
      while ($g.ElapsedMilliseconds -lt 15000) {
        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 100
      }
    }
  }
}

function Invoke-ThermalProbe {
  # Fixed-work probe at a session BOUNDARY, with no arm running. result.v1
  # requires thermal_state nominal at BOTH boundaries, and the probe is the
  # only Windows candidate that survived a falsifiable negative control (a 40%
  # processor cap slows it 2.892x, while ACPI Throttle Reasons stayed 0
  # through the same cap). It is two-sided fail-closed: unavailable reports
  # unknown, and a reference the observed run BEATS reports unknown with
  # reference_suspect rather than a false nominal.
  param([string]$Label)
  $probe = Join-Path $BenchRepo 'windows/bench/Measure-ThermalProbe.ps1'
  try {
    $raw = & $probe -Reps 6 2>&1 | Out-String
    $obj = $raw | ConvertFrom-Json
    Write-Host ("  thermal[$Label]: $($obj.thermal_state)  ratio=$($obj.ratio_to_reference)  suspect=$($obj.reference_suspect)  tempC=$($obj.context.temperature_c)")
    return $obj
  } catch {
    Write-Host "  thermal[$Label]: probe FAILED -- $($_.Exception.Message)"
    return $null
  }
}

function Get-Wv2Version {
  $k = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
  return (Get-ItemProperty $k -ErrorAction SilentlyContinue).pv
}

# --- session ----------------------------------------------------------------
$wv2Start = Get-Wv2Version
Write-Output "session start: WebView2 $wv2Start, seed $Seed, $Rounds rounds x $($ARMS.Count) arms"
$thermalStart = Invoke-ThermalProbe -Label 'start'

$records = New-Object System.Collections.ArrayList
foreach ($a in $ARMS) {
  Write-Output "  warmup (unscored): $($a.arm_id)"
  [void]$records.Add((Invoke-ArmRun -Arm $a -RoundNo 0 -IsWarmup $true))
}

function Invoke-ThermalGate {
  # Returns a record of what the gate observed, so a cooling pause is evidence
  # in the document rather than an invisible pause in the operator terminal.
  param([int]$AfterRound)
  $probe = Invoke-ThermalProbe -Label ("gate r$AfterRound")
  if ($null -eq $probe) { return [ordered]@{ after_round=$AfterRound; entered=$false; note='probe unavailable' } }
  if ($probe.thermal_state -eq 'nominal' -and -not $probe.reference_suspect) {
    return [ordered]@{ after_round=$AfterRound; entered=$false; state=$probe.thermal_state; ratio=$probe.ratio_to_reference }
  }
  Write-Host ("  cooling gate after r{0}: {1} (ratio {2}) -- idling until nominal" -f $AfterRound, $probe.thermal_state, $probe.ratio_to_reference)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $attempts = 0
  while ($sw.ElapsedMilliseconds -lt $ThermalGateMaxWaitMs) {
    Start-Sleep -Milliseconds $ThermalGatePollMs
    $attempts++
    $probe = Invoke-ThermalProbe -Label ("gate r$AfterRound try $attempts")
    if ($probe -and $probe.thermal_state -eq 'nominal' -and -not $probe.reference_suspect) {
      Write-Host ("  cooling gate after r{0}: nominal again after {1} ms" -f $AfterRound, $sw.ElapsedMilliseconds)
      return [ordered]@{ after_round=$AfterRound; entered=$true; recovered=$true; waited_ms=[int]$sw.ElapsedMilliseconds; attempts=$attempts; ratio=$probe.ratio_to_reference }
    }
  }
  Write-Host ("  cooling gate after r{0}: DID NOT recover within {1} ms" -f $AfterRound, $ThermalGateMaxWaitMs)
  return [ordered]@{ after_round=$AfterRound; entered=$true; recovered=$false; waited_ms=[int]$sw.ElapsedMilliseconds; attempts=$attempts }
}

$gateEvents = New-Object System.Collections.ArrayList
$rand = New-Object System.Random $Seed
$schedule = New-Object System.Collections.ArrayList
for ($r = 1; $r -le $Rounds; $r++) {
  # balanced: every arm exactly once per round, order randomized within the round
  $order = @($ARMS | Sort-Object { $rand.Next() })
  [void]$schedule.Add(($order | ForEach-Object { $_.arm_id }) -join '>')
  foreach ($a in $order) {
    $rec = Invoke-ArmRun -Arm $a -RoundNo $r -IsWarmup $false
    [void]$records.Add($rec)
    $shown = 'REJECTED ' + $rec.reject_reason
    if ($rec.valid) { $shown = "host=$($rec.diagnostics.host_ws_kib) fw=$($rec.diagnostics.framework_ws_kib) eng=$($rec.diagnostics.engine_ws_kib)x$($rec.diagnostics.engine_process_count)" }
    Write-Output ("  r{0,-3} {1,-6} {2}" -f $r, $a.arm_id, $shown)
  }
  if ($ThermalGateEveryRounds -gt 0 -and ($r % $ThermalGateEveryRounds) -eq 0 -and $r -lt $Rounds) {
    [void]$gateEvents.Add((Invoke-ThermalGate -AfterRound $r))
  }
}

# Cool before the CLOSING boundary as well. Gating only between rounds still
# leaves the final round's heat in the end probe. This is not hiding that the
# session heats the machine -- the per-round gates already bound in-session
# drift to at most $ThermalGateEveryRounds rounds, and every gate event is
# recorded in the document. This makes the closing boundary measure a settled
# machine, which is what 'nominal at both boundaries' is asking for.
if ($ThermalGateEveryRounds -gt 0) {
  [void]$gateEvents.Add((Invoke-ThermalGate -AfterRound $Rounds))
}
$thermalEnd = Invoke-ThermalProbe -Label 'end'
$wv2End = Get-Wv2Version
$integrity = 'ok'
if ($wv2Start -ne $wv2End) { $integrity = "WEBVIEW2_CHANGED_MIDSESSION $wv2Start -> $wv2End" }
Write-Output "session end: WebView2 $wv2End, integrity=$integrity"

$out = [ordered]@{
  seed = $Seed; rounds = $Rounds
  interleaving = 'round-robin-randomized'
  schedule = $schedule
  webview2_start = $wv2Start; webview2_end = $wv2End; integrity = $integrity
  thermal_start = $thermalStart; thermal_end = $thermalEnd
  thermal_gate_every_rounds = $ThermalGateEveryRounds
  thermal_gate_events = $gateEvents
  records = $records
}
if ($OutFile) {
  [System.IO.File]::WriteAllText($OutFile, ($out | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
  Write-Output "wrote $OutFile"
}
