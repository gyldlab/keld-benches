# Fixed-work thermal/throttle probe for Windows bench sessions.
#
# WHY A FIXED-WORK PROBE AND NOT A TEMPERATURE READING
# ----------------------------------------------------
# result.v1 environment.power.thermal_state says "Publication requires nominal
# at both session boundaries". Every obvious Windows source was tested against
# an INDUCED, independently-verified throttle on this machine, and all but one
# failed:
#
#   MSAcpi_ThermalZoneTemperature  Access denied unelevated. Elevating the
#                                  harness would change the token, integrity
#                                  level and Defender interaction of every
#                                  child it spawns -- perturbing the very
#                                  numbers being measured. Rejected.
#   Throttle Reasons               Stayed 0 through 95 s of 16-thread load at
#   % Passive Limit                78-90 C AND through a hard 40% processor
#                                  cap. They report "not throttled" while the
#                                  machine is provably throttled: these are
#                                  ACPI passive-cooling indicators, and this
#                                  laptop limits in AMD SMU/ASUS firmware,
#                                  below ACPI visibility. Rejected -- gating on
#                                  them would stamp "nominal" on a throttled
#                                  session, the exact failure thermal_state
#                                  exists to prevent.
#   absolute temperature band      Idle swept 70-91 C unprompted; full load
#                                  occupied 78-90 C. The distributions overlap
#                                  almost entirely -- no threshold separates
#                                  them. Rejected as a decision variable.
#   Win32_Processor
#     CurrentClockSpeed            Tracks an OS P-state cap (3201 -> 1291 MHz)
#                                  but read 3201 == Max throughout a burn where
#                                  delivered performance fell to 27-35%. Blind
#                                  to firmware limiting -- which is exactly the
#                                  kind a thermal criterion cares about.
#   % Processor Performance        Arithmetically entangled with utilization;
#                                  swung 25-115% at idle with no cap. Usable
#                                  only as corroboration while quiet.
#
# The fixed-work probe was the only candidate to survive a falsifiable
# negative control: on a quiet machine it is stable to max/min 1.01-1.02x, and
# a 40% processor cap slowed it 2.892x. Its calibration is monotone and
# reversible (cap 100/70/50/40/100 -> 1.000x/1.672x/2.313x/2.913x/1.000x), and
# two independent quiet baselines agreed to 0.77%. A 1.05 band therefore sits
# far inside the smallest detectable step (1.672x) and is limited only by
# ~1-2% measurement noise.
#
# Temperature and % Processor Performance are still RECORDED, as descriptive
# provenance. They are context, never the gate.

[CmdletBinding()]
param(
  [long]$Iterations = 40000000,
  [int]$Reps = 10,
  # nominal iff observed/reference <= this. 1.05 is ~1/12 of the smallest
  # throttle step the probe can resolve, and ~3x the observed noise floor.
  [double]$NominalBand = 1.05,
  # ns/iter on a known-quiet machine. Measured here: 2.464 and 2.483 in two
  # independent runs (0.77% apart). Machine-specific: recalibrate per machine.
  [double]$ReferenceFloorNsPerIter = 2.464,
  [switch]$Calibrate
)

$ErrorActionPreference = 'Stop'

# The work loop is COMPILED, not interpreted. A PowerShell loop runs the same
# arithmetic ~1000x slower and its wall time is dominated by interpreter
# overhead, which is exactly the thing that must NOT be in the signal: the
# probe has to be sensitive to CPU clock, not to script-engine noise.
Add-Type -TypeDefinition @"
public static class KeldFixedWork {
    public static int Run(long iters) {
        int acc = 0;
        for (long i = 0; i < iters; i++) { acc = (acc + (int)i) & 0xFFFFFF; }
        return acc;
    }
}
"@ -ErrorAction SilentlyContinue

function Invoke-FixedWork {
  <#
    Deliberately trivial integer work: no allocation, no I/O, no syscalls, so
    the only thing that can change its wall time is how fast the CPU is
    actually running. Pinned to one core and raised above normal priority so
    scheduler noise and core migration do not masquerade as throttling.
    min-of-N, never mean: the minimum is the least-interfered-with sample.
  #>
  param([long]$Iters, [int]$Repetitions)

  $proc = [System.Diagnostics.Process]::GetCurrentProcess()
  $oldAffinity = $proc.ProcessorAffinity
  $oldPriority = $proc.PriorityClass
  $times = New-Object System.Collections.ArrayList
  try {
    $proc.ProcessorAffinity = [IntPtr]1          # CPU0 only
    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
    [void][KeldFixedWork]::Run(100000)   # JIT warm-up, not timed
    for ($r = 0; $r -lt $Repetitions; $r++) {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $acc = [KeldFixedWork]::Run($Iters)
      $sw.Stop()
      [void]$times.Add($sw.Elapsed.TotalMilliseconds)
      # $acc is consumed so the JIT cannot eliminate the loop as dead code.
      if ($acc -eq -1) { Write-Output 'unreachable' }
    }
  }
  finally {
    $proc.ProcessorAffinity = $oldAffinity
    $proc.PriorityClass = $oldPriority
  }
  $min = ($times | Measure-Object -Minimum).Minimum
  $max = ($times | Measure-Object -Maximum).Maximum
  return [ordered]@{
    min_ms       = [math]::Round($min, 3)
    max_ms       = [math]::Round($max, 3)
    spread_ratio = [math]::Round($max / $min, 4)
    ns_per_iter  = [math]::Round(($min * 1000000.0) / $Iters, 4)
    reps         = $Repetitions
    iterations   = $Iters
  }
}

function Get-ThermalContext {
  # Descriptive only. Never a gate -- see the header for why each of these
  # failed its negative control.
  $tempC = $null
  $procPerf = $null
  $procUtil = $null
  try {
    $t = (Get-Counter '\Thermal Zone Information(*)\High Precision Temperature' -ErrorAction Stop).CounterSamples |
         Where-Object { $_.InstanceName -match 'thrm' } | Select-Object -First 1
    if ($t) { $tempC = [math]::Round(($t.CookedValue / 10.0) - 273.15, 2) }
  } catch {}
  try { $procPerf = [math]::Round((Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue, 1) } catch {}
  try { $procUtil = [math]::Round((Get-Counter '\Processor Information(_Total)\% Processor Utility' -ErrorAction Stop).CounterSamples[0].CookedValue, 1) } catch {}
  return [ordered]@{
    temperature_c            = $tempC
    percent_processor_perf   = $procPerf
    percent_processor_utility= $procUtil
    note                     = 'descriptive context only; not the thermal_state decision variable'
  }
}

if ($Calibrate) {
  Write-Output "calibrating on a QUIET machine -- close other workloads first"
  $c = Invoke-FixedWork -Iters $Iterations -Repetitions $Reps
  Write-Output ("reference_floor_ns_per_iter = {0}  (min {1} ms, spread {2}x over {3} reps)" -f `
    $c.ns_per_iter, $c.min_ms, $c.spread_ratio, $c.reps)
  Write-Output "Pass this as -ReferenceFloorNsPerIter for this machine."
  return
}

$work = Invoke-FixedWork -Iters $Iterations -Repetitions $Reps
$ctx  = Get-ThermalContext
$ratio = [math]::Round($work.ns_per_iter / $ReferenceFloorNsPerIter, 4)

# Fail closed: if the probe could not run, thermal_state is 'unknown', never
# 'nominal'. An unavailable probe must not silently become a pass.
$state = 'unknown'
if ($null -ne $work.ns_per_iter -and $work.ns_per_iter -gt 0) {
  if ($ratio -le $NominalBand) { $state = 'nominal' } else { $state = 'throttled' }
}

$result = [ordered]@{
  thermal_state             = $state
  ratio_to_reference        = $ratio
  nominal_band              = $NominalBand
  reference_floor_ns_per_iter = $ReferenceFloorNsPerIter
  observed_ns_per_iter      = $work.ns_per_iter
  probe                     = $work
  context                   = $ctx
  sampled_utc               = (Get-Date).ToUniversalTime().ToString('o')
  method                    = 'fixed-work min-of-N, CPU0-pinned, AboveNormal; ratio vs per-machine quiet-baseline floor'
}
$result | ConvertTo-Json -Depth 6
