# Emit a result.v1 document for a paired, round-major interleaved GUI session.
#
# WHAT IS COMPARED, AND WHY ONLY THIS
# -----------------------------------
# The comparison block compares the NATIVE HOST process of each framework,
# because that is the only like-for-like quantity these two arms share. The
# Keld arm additionally runs application JavaScript in a supervised Bun child
# over authenticated kipc; the Tauri fixture backend is
# tauri::Builder::default().run() and runs NO application JavaScript at all.
# Putting Keld-host-plus-runtime against a backend that runs no JS would not
# be a peer result, so host+runtime is recorded as a per-run DIAGNOSTIC and
# never enters the comparison.
#
# This also matches the registry: metrics.v1.json MEM-IDLE says the scored
# value is "the Keld-owned (main) RSS", i.e. the main process. RSS is RESIDENT
# set size, so the counter is the working set.
#
# PAIRED RATIO CI. Nothing in this repo computed a paired ratio interval
# before. Rounds are the pairing unit: every round contains exactly one launch
# of each arm, in randomized order, so a per-round ratio cancels drift that
# affects both arms. The interval is a percentile bootstrap OVER ROUNDS
# (resampling whole rounds, not individual samples), which preserves the
# pairing. Verdict follows metrics.v1.json regression_rule.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BenchRepo,
  [Parameter(Mandatory = $true)][string]$KeldRepo,
  [Parameter(Mandatory = $true)][string]$SessionJson,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [switch]$AllowDirtyTree
)

$ErrorActionPreference = 'Stop'

function Get-TreeState { param([string]$Repo)
  $p = & git -C $Repo status --porcelain
  if ([string]::IsNullOrWhiteSpace(($p | Out-String))) { return 'clean' }
  return 'dirty' }

function Assert-AtCommit { param([string]$Repo, [string]$Sha, [string]$Rel)
  $null = & git -C $Repo show "${Sha}:$Rel" 2>$null
  if ($LASTEXITCODE -ne 0) { throw "PROVENANCE FAILED: $Rel does not exist at $Sha" }
  $d = & git -C $Repo status --porcelain -- $Rel
  if (-not [string]::IsNullOrWhiteSpace(($d | Out-String))) { throw "PROVENANCE FAILED: $Rel differs from its blob at $Sha" }
  return (Get-FileHash (Join-Path $Repo $Rel) -Algorithm SHA256).Hash.ToLower() }

$benchSha = (& git -C $BenchRepo rev-parse HEAD).Trim()
$keldSha  = (& git -C $KeldRepo rev-parse HEAD).Trim()
$tree     = Get-TreeState -Repo $BenchRepo
Write-Output "bench_sha=$benchSha tree=$tree keld_sha=$keldSha"
if ($tree -ne 'clean' -and -not $AllowDirtyTree) {
  throw "PROVENANCE FAILED: keld-benches tree is '$tree'. Commit before emitting."
}
$runnerRel = 'windows/bench/Measure-WindowsGuiSession.ps1'
$emitRel   = 'windows/bench/Emit-PairedSession.ps1'
# The keld ARTIFACT must actually correspond to keld_sha. Assert-AtCommit
# validates bench harness files against bench_sha, but nothing validated the
# measured Keld binary -- and on 2026-08-25 the Keld repo moved to a commit
# touching 1399 lines of product source while target/release/keld.exe was still
# the binary built from the previous one. A document recording keld_sha alone
# would have claimed code the measured binary does not contain.
#
# A binary cannot embed the sha it was built from, so the checkable invariant is
# ordering: an artifact built BEFORE its claimed commit existed cannot be that
# commit. Fails closed; a dirty keld tree is also refused, since then keld_sha
# does not describe the source either.
$keldDirty = & git -C $KeldRepo status --porcelain
if (-not [string]::IsNullOrWhiteSpace(($keldDirty | Out-String))) {
  throw "PROVENANCE FAILED: the keld repo tree is dirty, so keld_sha $keldSha does not describe the source the artifact was built from."
}
$keldCommitUtc = [datetime]::Parse((& git -C $KeldRepo show -s --format=%cI $keldSha)).ToUniversalTime()
$keldExePath = Join-Path $KeldRepo 'target/release/keld.exe'
if (-not (Test-Path $keldExePath)) { throw "PROVENANCE FAILED: no keld.exe at $keldExePath" }
$keldExeUtc = (Get-Item $keldExePath).LastWriteTimeUtc
if ($keldExeUtc -lt $keldCommitUtc) {
  throw ("PROVENANCE FAILED: keld.exe was built {0:u} but keld_sha {1} was committed {2:u}. " -f $keldExeUtc, $keldSha.Substring(0,12), $keldCommitUtc) +
        "The measured binary predates the commit it would be attributed to. Rebuild at this sha, or check out the sha the binary was built from."
}
Write-Output ("keld artifact provenance OK: exe {0:u} >= commit {1:u}" -f $keldExeUtc, $keldCommitUtc)

$runnerSha = Assert-AtCommit -Repo $BenchRepo -Sha $benchSha -Rel $runnerRel
$null      = Assert-AtCommit -Repo $BenchRepo -Sha $benchSha -Rel $emitRel
Write-Output "provenance OK: runner=$($runnerSha.Substring(0,16))"

$sess = Get-Content $SessionJson -Raw | ConvertFrom-Json

# --- payload parity, PROVEN from the measured artifact ------------------------
# HARNESS-CONTRACT.md requires a byte-identical canonical payload across arms,
# recorded as provenance.payload_sha256. It is only meaningful if it is
# recovered from what was MEASURED. On 2026-08-24 a Tauri artifact cited by two
# committed documents turned out to embed a beacon-instrumented page; a source
# file hash would have happily agreed with itself and hidden that.
#
# Keld  : the staged index.html the harness actually launched against.
# Tauri : the page extracted from inside the exe whose sha256 this document
#         cites, via windows/bench/extract_tauri_payload.py.
# Emission FAILS if they disagree. An unprovable parity claim is worse than none.
$payloadSha = $null
if ($sess.canonical_payload_sha256) {
  $keldPayload = [string]$sess.canonical_payload_sha256
  $tauriExe = Join-Path $BenchRepo 'windows/tauri/hello/src-tauri/target/release/tauri-hello.exe'
  $extractor = Join-Path $BenchRepo 'windows/bench/extract_tauri_payload.py'
  $null = & python $extractor $tauriExe --expect-sha256 $keldPayload
  if ($LASTEXITCODE -ne 0) {
    throw "PAYLOAD PARITY FAILED: the Tauri artifact does not embed the canonical page ($keldPayload). Exit $LASTEXITCODE."
  }
  $payloadSha = $keldPayload
  Write-Output "payload parity verified: both arms deliver $payloadSha"
} else {
  Write-Output "payload parity: NOT claimed (session ran without -CanonicalPayload)"
}

function Get-Median { param([double[]]$v)
  $s = $v | Sort-Object; $n = $s.Count; if ($n -eq 0) { return $null }
  if ($n % 2 -eq 1) { return [double]$s[[int](($n-1)/2)] }
  return [double](($s[$n/2-1] + $s[$n/2]) / 2) }
function Get-NearestRank { param([double[]]$v, [double]$p)
  $s = $v | Sort-Object; $n = $s.Count; if ($n -eq 0) { return $null }
  $r = [math]::Ceiling($p*$n); if ($r -lt 1) { $r = 1 }; if ($r -gt $n) { $r = $n }
  return [double]$s[$r-1] }
function Get-BootstrapCi95 { param([double[]]$v, [int]$Resamples = 10000, [int]$Seed = 20260824)
  if ($v.Count -lt 2) { return $null }
  $rand = New-Object System.Random $Seed
  $m = New-Object System.Collections.ArrayList
  for ($r = 0; $r -lt $Resamples; $r++) {
    $smp = New-Object double[] $v.Count
    for ($k = 0; $k -lt $v.Count; $k++) { $smp[$k] = $v[$rand.Next(0, $v.Count)] }
    [void]$m.Add((Get-Median $smp)) }
  $s = $m | Sort-Object
  return [ordered]@{ lower = [double]$s[[int][math]::Floor(0.025*($Resamples-1))]
                     upper = [double]$s[[int][math]::Ceiling(0.975*($Resamples-1))]
                     resamples = $Resamples } }

# Paired ratio bootstrap: resample ROUNDS with replacement, preserving pairing.
function Get-PairedRatioCi95 {
  param([double[]]$Ratios, [int]$Resamples = 10000, [int]$Seed = 20260824)
  if ($Ratios.Count -lt 2) { return $null }
  $rand = New-Object System.Random $Seed
  $meds = New-Object System.Collections.ArrayList
  for ($r = 0; $r -lt $Resamples; $r++) {
    $smp = New-Object double[] $Ratios.Count
    for ($k = 0; $k -lt $Ratios.Count; $k++) { $smp[$k] = $Ratios[$rand.Next(0, $Ratios.Count)] }
    [void]$meds.Add((Get-Median $smp)) }
  $s = $meds | Sort-Object
  return [ordered]@{ lower = [math]::Round([double]$s[[int][math]::Floor(0.025*($Resamples-1))], 6)
                     upper = [math]::Round([double]$s[[int][math]::Ceiling(0.975*($Resamples-1))], 6) } }

# --- build arms --------------------------------------------------------------
$armIds = @($sess.records | ForEach-Object { $_.arm } | Select-Object -Unique)
$arms = @()
$byArm = @{}
foreach ($id in $armIds) {
  $recs = @($sess.records | Where-Object { $_.arm -eq $id })
  $byArm[$id] = $recs
  $valid = @($recs | Where-Object { $_.valid })
  $vals = @($valid | ForEach-Object { [double]$_.value })
  $samples = @()
  foreach ($r in $recs) {
    $d = $r.diagnostics
    $diag = $null
    if ($d) {
      $diag = [ordered]@{
        host_ws_kib           = [double]$d.host_ws_kib
        host_private_kib      = [double]$d.host_private_kib
        runtime_ws_kib        = [double]$d.runtime_ws_kib
        runtime_private_kib   = [double]$d.runtime_private_kib
        runtime_process_count = [int]$d.runtime_process_count
        engine_ws_kib         = [double]$d.engine_ws_kib
        engine_process_count  = [int]$d.engine_process_count
        framework_ws_kib      = [double]$d.framework_ws_kib
        framework_private_kib = [double]$d.framework_private_kib
        tree_ws_kib           = [double]$d.tree_ws_kib
        native_window_ms      = [double]$d.native_window_ms
        settle_ms             = [double]$d.settle_ms
        drift_observed        = [double]$d.drift_observed
        round                 = [int]$r.round
        warmup                = [bool]$r.warmup
        counter               = [string]$d.counter
      }
    }
    $samples += [ordered]@{
      run = ([int]$r.round * 10 + [array]::IndexOf($armIds, $id) + 1)
      value = $(if ($null -ne $r.value) { [double]$r.value } else { $null })
      valid = [bool]$r.valid
      reject_reason = $r.reject_reason
      diagnostics = $diag
    }
  }
  $fw = 'Keld host-owned hello (keld dev)'
  $fixture = 'windows/keld/hello/'
  $artifact = (Get-FileHash (Join-Path $KeldRepo 'target\release\keld.exe') -Algorithm SHA256).Hash.ToLower()
  $base = 'keld.exe'
  if ($id -eq 'tauri') {
    $fw = 'Tauri 2 hello'
    $fixture = 'windows/tauri/hello/'
    $artifact = (Get-FileHash (Join-Path $BenchRepo 'windows\tauri\hello\src-tauri\target\release\tauri-hello.exe') -Algorithm SHA256).Hash.ToLower()
    $base = 'tauri-hello.exe'
  }
  $arms += [ordered]@{
    arm_id = $id
    framework = [ordered]@{ name = $fw; version = '0.0.1' }
    fixture_path = $fixture
    lane = 'webview2'
    role = 'score'
    artifact = [ordered]@{ sha256 = $artifact; basename = $base; version = '0.0.1' }
    samples = $samples
    statistics = [ordered]@{
      valid_samples = $valid.Count
      median = (Get-Median $vals); p90 = (Get-NearestRank $vals 0.90); p99 = $null
      min = ($vals | Measure-Object -Minimum).Minimum
      max = ($vals | Measure-Object -Maximum).Maximum
      bootstrap_ci95 = (Get-BootstrapCi95 $vals)
    }
  }
}

# --- paired ratio, keld vs tauri, by round ----------------------------------
$ratios = New-Object System.Collections.ArrayList
$rounds = @($sess.records | Where-Object { -not $_.warmup } | ForEach-Object { $_.round } | Select-Object -Unique | Sort-Object)
foreach ($rd in $rounds) {
  $k = @($byArm['keld']  | Where-Object { $_.round -eq $rd -and $_.valid })
  $t = @($byArm['tauri'] | Where-Object { $_.round -eq $rd -and $_.valid })
  if ($k.Count -eq 1 -and $t.Count -eq 1) {
    [void]$ratios.Add([double]$k[0].value / [double]$t[0].value)
  }
}
$ratioArr = @($ratios | ForEach-Object { [double]$_ })
$ci = Get-PairedRatioCi95 -Ratios $ratioArr
$verdict = 'INCONCLUSIVE'
$THRESH = 1.05
if ($ci) {
  if ($ci.lower -gt $THRESH) { $verdict = 'FAIL' }
  elseif ($ci.upper -le $THRESH) { $verdict = 'PASS' }
}
Write-Output ("paired rounds=$($ratioArr.Count)  median ratio=$([math]::Round((Get-Median $ratioArr),4))  ci95=[$($ci.lower), $($ci.upper)]  verdict=$verdict")

# --- environment -------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
$ac = $true; if ($bat) { $ac = ($bat.BatteryStatus -ne 1) }
# The block below says eligibility is DERIVED, never hand-authored -- and the
# thermal check then read -ThermalStart/-ThermalEnd, which the operator types.
# In practice they matched the measurement, but a gate that reads what someone
# typed is not a gate: 'nominal' for a throttled session would have published.
# Both boundary probes are already in the session JSON. Fail closed.
foreach ($boundary in @('thermal_start', 'thermal_end')) {
  if ([string]::IsNullOrWhiteSpace($sess.$boundary.thermal_state)) {
    throw "PROVENANCE FAILED: the session JSON has no $boundary.thermal_state, so the thermal boundary is unknown and cannot be asserted."
  }
}
$thermalStartState = [string]$sess.thermal_start.thermal_state
$thermalEndState   = [string]$sess.thermal_end.thermal_state
$thermalSuspect    = ([bool]$sess.thermal_start.reference_suspect) -or ([bool]$sess.thermal_end.reference_suspect)
Write-Output ("thermal boundaries (measured): start=$thermalStartState end=$thermalEndState suspect=$thermalSuspect")

$thermal = 'unknown'
if ($thermalStartState -eq 'nominal' -and $thermalEndState -eq 'nominal' -and -not $thermalSuspect) { $thermal = 'nominal' }

# --- publication eligibility: DERIVED, never hand-authored --------------------
# Stream-B finding, the hard way: publication blocks written by whoever emits are
# just claims. schema/check.py never reads {os}/bench/results/, so a document
# could assert eligible=true on three samples and nothing would object. These
# checks are mechanical, evaluated against THIS document and the registry policy.
$reasons = @()
$policySamples = 30   # metrics.v1.json sample_policy: gui-paint-rss

foreach ($a in $arms) {
  if ($a.statistics.valid_samples -lt $policySamples) {
    $reasons += [ordered]@{ code='SAMPLES_BELOW_POLICY'; label="arm $($a.arm_id) has $($a.statistics.valid_samples) valid samples; gui-paint-rss policy requires $policySamples" }
  }
  if (-not $a.artifact.sha256) {
    $reasons += [ordered]@{ code='ARTIFACT_UNHASHED'; label="arm $($a.arm_id) has no Release artifact sha256" }
  }
}
if ($arms.Count -lt 2) {
  $reasons += [ordered]@{ code='NO_PAIRED_ARM'; label='fewer than two arms in the session' }
}
if ($tree -ne 'clean') {
  $reasons += [ordered]@{ code='TREE_NOT_CLEAN'; label="bench tree was '$tree' at emission" }
}
if ($thermalStartState -ne 'nominal' -or $thermalEndState -ne 'nominal') {
  $reasons += [ordered]@{ code='THERMAL_STATE_UNVERIFIED'; label="fixed-work probe measured start=$thermalStartState end=$thermalEndState; publication requires nominal at BOTH boundaries" }
}
# reference_suspect means the quiet-baseline floor was calibrated on a busy
# machine, so every ratio measured against it is understated -- including the
# ones that just reported 'nominal'. Nothing consumed this flag before.
if ($thermalSuspect) {
  $reasons += [ordered]@{ code='THERMAL_REFERENCE_SUSPECT'; label='a boundary probe ran FASTER than the claimed quiet-baseline floor, so the floor is not a quiet baseline and every ratio against it is understated' }
}
if (-not $ac) {
  $reasons += [ordered]@{ code='NOT_ON_AC_POWER'; label='machine was not on AC power; HARNESS-CONTRACT.md requires AC power with Low Power Mode off' }
}
if (-not $payloadSha) {
  $reasons += [ordered]@{ code='PAYLOAD_PARITY_UNPROVEN'; label='no canonical payload was verified across arms; HARNESS-CONTRACT.md requires a byte-identical payload recorded as provenance.payload_sha256' }
}
if ($sess.integrity -ne 'ok') {
  $reasons += [ordered]@{ code='SESSION_INTEGRITY_FAILED'; label=[string]$sess.integrity }
}
# A cooling gate that fired and never returned to nominal means part of the
# session ran outside the thermal band, which the boundary probes cannot see:
# they sample the ends, not the middle. Nothing checked this before, so a
# session could enter a gate, fail to recover, and still publish.
foreach ($gate in @($sess.thermal_gate_events)) {
  if ($gate -and $gate.entered -and -not $gate.recovered) {
    $why = if ($gate.probe_unavailable) { 'the probe was unavailable' } else { "it did not return to nominal within $($gate.waited_ms) ms" }
    $reasons += [ordered]@{ code='THERMAL_GATE_UNRECOVERED'; label="cooling gate after round $($gate.after_round) entered and $why" }
  }
}
$eligible = ($reasons.Count -eq 0)
Write-Output ("publication: eligible=$eligible  (" + $reasons.Count + " blocking reason(s))")

# The session start was a hardcoded literal until 2026-08-25, so every emitted
# document carried '2026-08-24T20:10:00' regardless of when it actually ran --
# the 2026-08-25 paired document claimed a start ~15 hours before its own
# finished_utc. That is the false-provenance class this pipeline exists to
# prevent, sitting in the pipeline itself.
#
# The opening thermal probe is the session's first measured event and already
# stamps a real sampled_utc, so it IS the session start; taking it keeps one
# source of truth rather than adding a second timestamp for the runner to drift
# against. Fail closed: no boundary probe, no emission.
$startedUtc = $sess.thermal_start.sampled_utc
if ([string]::IsNullOrWhiteSpace($startedUtc)) {
  throw "PROVENANCE FAILED: the session JSON has no thermal_start.sampled_utc, so the session start time is unknown. Emitting a placeholder would put a false timestamp in a published document."
}
# finished_utc was (Get-Date) at EMISSION, not the end of the session. It read
# correctly only while emission immediately followed the run; re-emitting the
# same session hours later stretched the recorded window to ~5 hours. Same class
# as the hardcoded start: a field inside `session` describing the emitter.
# The closing thermal probe is the session's last measured event.
$finishedUtc = $sess.thermal_end.sampled_utc
if ([string]::IsNullOrWhiteSpace($finishedUtc)) {
  throw "PROVENANCE FAILED: the session JSON has no thermal_end.sampled_utc, so the session end time is unknown. Emitting the current clock would record when the document was written, not when the session ran."
}
Write-Output ("session started_utc (opening thermal probe): {0}" -f $startedUtc)
Write-Output ("session finished_utc (closing thermal probe): {0}" -f $finishedUtc)

$doc = [ordered]@{
  schema_version = 1
  metric = [ordered]@{ id = 'MEM-IDLE'; unit = 'KiB'; registry_version = 1 }
  cache_state = 'fresh-process'
  session = [ordered]@{
    started_utc = $startedUtc
    finished_utc = $finishedUtc
    requested_samples = [int]$sess.rounds
    interleaving = 'round-robin-randomized'
    label = 'kel25-windows-keld-vs-tauri-paired-30'
    notes = ('First PAIRED Windows measurement in this repo. Round-major randomized interleaving, seed ' + $sess.seed + ': every round runs each arm exactly once, order shuffled within the round, so drift over the session cannot land on one arm. Both arms drive the SAME system engine build (WebView2 Evergreen ' + $sess.webview2_start + '), verified identical at both session boundaries. SCORED VALUE is the native host process working set for both arms: RSS is RESIDENT set size and metrics.v1.json MEM-IDLE directs scoring "the Keld-owned (main) RSS". THE COMPARISON IS HOST-TO-HOST ONLY. The Keld arm additionally runs application JavaScript in a supervised Bun child over authenticated kipc; the Tauri fixture backend is tauri::Builder::default().run() and runs no application JavaScript at all. framework_ws_kib (host+runtime) is recorded per run as a diagnostic and is deliberately excluded from the comparison block, because comparing a host-plus-JS-runtime against a backend that runs no JS is not a peer result. The first launch of each arm is an explicit unscored WARMUP sample, recorded with reason WARMUP_UNSCORED rather than silently dropped, because Defender first-touch of a fresh binary is a large outlier and interleaving relocates that bias onto whichever arm draws round 1 rather than removing it. Paired ratio CI resamples whole ROUNDS with replacement so the pairing is preserved. DISCLOSURES, none of which block publication under HARNESS-CONTRACT.md but all of which bound how this number may be read. (1) CAPABILITY ASYMMETRY: the Keld arm runs application JavaScript in a supervised Bun child over authenticated kipc; the Tauri fixture backend is a bare tauri::Builder that runs none. The comparison is native-host-to-native-host only. framework_ws_kib (host+runtime) is recorded per run and deliberately excluded from the comparison block; do not read this as total application footprint. (2) PAYLOAD PARITY IS SOURCE-LEVEL, NOT ENVIRONMENT-LEVEL: both arms are handed byte-identical document bytes, verified by extracting the page from the Tauri artifact this document cites, but the rendered environments are not identical. Tauri exposes __TAURI_INTERNALS__, __TAURI_EVENT_PLUGIN_INTERNALS__, ipc and isTauri before the document runs and loads via a custom asset protocol at http://tauri.localhost; Keld exposes none of those and loads via NavigateToString at origin null. (3) REGISTRY SCOPE: architecture 01 section 5 budgets the sum of keld processes while the metrics.v1.json note directs scoring the Keld-owned (main) RSS. This document scores the main process, which is also the only like-for-like quantity across the two arms. Both readings pass the budget, so it changes no verdict, but the registry should still state which is scored. (4) TAURI NPM LAYER UNPINNED: windows/tauri/hello/package-lock.json is gitignored, so that fixture npm layer is not reproducible from this repo. Its Cargo.lock is committed and the CLI is not on the measured build path. (5) SCOPE: the Keld arm measures the full keld dev developer flow (doctor checks, echo server, supervised Bun spawn, authenticated kipc echo, then window) against a packaged Tauri Release exe. Payload parity does not make these scope-matched.')
  }
  environment = [ordered]@{
    os = [ordered]@{ name = 'windows'; version = $os.Caption; build = "$($os.Version)" }
    hardware = [ordered]@{ cpu = $cpu; arch = $env:PROCESSOR_ARCHITECTURE; ram_bytes = [int64]$cs.TotalPhysicalMemory; machine_label = 'windows-local-2026-08-24' }
    power = [ordered]@{ ac_power = [bool]$ac; low_power_mode = $false; thermal_state = $thermal }
    engine = [ordered]@{ name = 'WebView2 Evergreen'; version = [string]$sess.webview2_start }
    toolchains = @(
      [ordered]@{ name = 'rustc'; version = ((rustc --version) -join '') }
      [ordered]@{ name = 'bun'; version = ((bun --revision) -join '') }
      [ordered]@{ name = 'keld-cli'; version = '0.0.1' }
      [ordered]@{ name = 'tauri'; version = '2.11.5' }
    )
  }
  provenance = [ordered]@{
    bench_sha = $benchSha; bench_tree_state = $tree; keld_sha = $keldSha
    harness = [ordered]@{ path = $runnerRel; sha256 = $runnerSha; version = 'kel25-paired-gui-v1' }
    payload_sha256 = $payloadSha
    fixtures = @(
      [ordered]@{ path = 'windows/keld/hello/'; sha = $benchSha }
      [ordered]@{ path = 'windows/tauri/hello/'; sha = $benchSha }
    )
  }
  arms = $arms
  comparison = [ordered]@{
    baseline_arm = 'tauri'
    candidate_arm = 'keld'
    ratio_ci95 = [ordered]@{ lower = $ci.lower; upper = $ci.upper }
    threshold = $THRESH
    verdict = $verdict
    method = 'paired percentile bootstrap over rounds, 10000 resamples, ratio = keld host working set / tauri host working set within the same round'
  }
  publication = [ordered]@{ policy_version = 1; requested = $true; eligible = $eligible; reasons = $reasons }
}

[System.IO.File]::WriteAllText($OutFile, ($doc | ConvertTo-Json -Depth 14), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "wrote $OutFile"
& python (Join-Path $BenchRepo 'windows\bench\validate_result_v1.py') $BenchRepo $OutFile
if ($LASTEXITCODE -ne 0) { throw "EMISSION FAILED VALIDATION: exit $LASTEXITCODE" }
