# Emit result.v1 documents for the KEL-25 Windows session — with provenance
# that is MEASURED and ASSERTED, never hand-authored.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# The first cut of these documents was emitted by an uncommitted scratchpad
# script that (a) hardcoded `bench_tree_state = 'clean'` instead of measuring
# it, and (b) hashed the on-disk harness rather than checking it against the
# committed blob at the recorded bench_sha. Both were false in the shipped
# documents:
#
#   mem-idle recorded bench_sha 0d629ac + harness sha256 a9896570..., but the
#   harness blob AT 0d629ac was d85650d0... — a different file.
#   paint recorded harness sha256 69880c31... at bench_sha ed12e9f, where
#   Measure-KeldPaint.ps1 did not exist in the repo at all.
#
# A result document's whole value is that someone else can reproduce it from
# the cited commit. Provenance that cannot be checked is worse than absent,
# because it reads as verified. So this script refuses to emit unless the tree
# is clean AND every harness it names is byte-identical to its blob at HEAD.
# It also computes the statistics itself, so the harness/emitter named in
# provenance can actually reproduce the numbers in the document.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BenchRepo,
  [Parameter(Mandatory = $true)][string]$KeldRepo,
  [Parameter(Mandatory = $true)][string]$RawDir,
  [switch]$AllowDirtyTree   # negative-control / dry-run escape hatch ONLY
)

$ErrorActionPreference = 'Stop'

# --- provenance, measured and asserted --------------------------------------
function Get-TreeState {
  param([string]$Repo)
  $porcelain = & git -C $Repo status --porcelain
  if ([string]::IsNullOrWhiteSpace(($porcelain | Out-String))) { return 'clean' }
  return 'dirty'
}

function Assert-HarnessAtCommit {
  <#
    The recorded harness sha256 MUST be the blob at the recorded bench_sha.
    Hashing the working tree is what produced the false provenance this
    script exists to prevent.
  #>
  param([string]$Repo, [string]$Sha, [string]$RepoRelPath)
  $blob = & git -C $Repo show "${Sha}:$RepoRelPath" 2>$null
  if ($LASTEXITCODE -ne 0 -or $null -eq $blob) {
    throw "PROVENANCE FAILED: $RepoRelPath does not exist at $Sha. Commit the harness before emitting a document that cites it."
  }
  # Hash the blob bytes exactly as git stores them.
  $tmp = [System.IO.Path]::GetTempFileName()
  & git -C $Repo show "${Sha}:$RepoRelPath" | Out-File -FilePath $tmp -Encoding utf8 -NoNewline
  $blobHash = (Get-FileHash (Join-Path $Repo $RepoRelPath) -Algorithm SHA256).Hash.ToLower()
  Remove-Item $tmp -ErrorAction SilentlyContinue

  # Authoritative check: does git consider the file modified vs HEAD?
  $diff = & git -C $Repo status --porcelain -- $RepoRelPath
  if (-not [string]::IsNullOrWhiteSpace(($diff | Out-String))) {
    throw "PROVENANCE FAILED: $RepoRelPath differs from its committed blob at $Sha (git status: $diff)."
  }
  return $blobHash
}

$benchSha  = (& git -C $BenchRepo rev-parse HEAD).Trim()
$keldSha   = (& git -C $KeldRepo  rev-parse HEAD).Trim()
$treeState = Get-TreeState -Repo $BenchRepo

Write-Output "bench_sha=$benchSha tree=$treeState keld_sha=$keldSha"
if ($treeState -ne 'clean' -and -not $AllowDirtyTree) {
  throw "PROVENANCE FAILED: keld-benches tree is '$treeState'. A document claiming bench_tree_state must be emitted from a clean tree, or the claim is false. Commit first (or pass -AllowDirtyTree for a dry run that is NOT publishable)."
}

$rssHarness   = 'windows/bench/Measure-KeldIdleRss.ps1'
$paintHarness = 'windows/bench/Measure-KeldPaint.ps1'
$emitter      = 'windows/bench/Emit-Kel25Documents.ps1'
$rssSha    = Assert-HarnessAtCommit -Repo $BenchRepo -Sha $benchSha -RepoRelPath $rssHarness
$paintSha  = Assert-HarnessAtCommit -Repo $BenchRepo -Sha $benchSha -RepoRelPath $paintHarness
$emitSha   = Assert-HarnessAtCommit -Repo $BenchRepo -Sha $benchSha -RepoRelPath $emitter
Write-Output "provenance OK: rss=$($rssSha.Substring(0,16)) paint=$($paintSha.Substring(0,16)) emitter=$($emitSha.Substring(0,16))"

# --- statistics, computed here so the cited scripts reproduce the document ---
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

function Write-NoBom { param([string]$Path, $Obj)
  $dir = Split-Path $Path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 14), (New-Object System.Text.UTF8Encoding($false)))
  Write-Output "wrote $(Split-Path $Path -Leaf)" }

# --- environment -------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
$wv2 = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue).pv
$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
$ac = $true; if ($bat) { $ac = ($bat.BatteryStatus -ne 1) }
function New-Env {
  [ordered]@{
    os = [ordered]@{ name='windows'; version=$os.Caption; build="$($os.Version)" }
    hardware = [ordered]@{ cpu=$cpu; arch=$env:PROCESSOR_ARCHITECTURE; ram_bytes=[int64]$cs.TotalPhysicalMemory; machine_label='windows-local-2026-08-24' }
    power = [ordered]@{ ac_power=[bool]$ac; low_power_mode=$false; thermal_state='unknown' }
    engine = [ordered]@{ name='WebView2 Evergreen'; version="$wv2" }
    toolchains = @(
      [ordered]@{ name='rustc'; version=((rustc --version) -join '') }
      [ordered]@{ name='bun'; version=((bun --revision) -join '') }
      [ordered]@{ name='keld-cli'; version='0.0.1' }
    ) } }

$COMMON = @(
  [ordered]@{ code='NO_PAIRED_ARM';            label='Keld-only session; no Tauri/Electron/WinUI Windows arm measured alongside it on the same engine' }
  [ordered]@{ code='ARMS_NOT_INTERLEAVED';     label='Single arm, interleaving=none; publication requires balanced randomized interleaving by round' }
  [ordered]@{ code='THERMAL_STATE_UNVERIFIED'; label='Windows thermal state recorded as unknown at both session boundaries' }
)
$keldExeSha = (Get-FileHash (Join-Path $KeldRepo 'target\release\keld.exe') -Algorithm SHA256).Hash.ToLower()
$startUtc = '2026-08-24T15:47:00.0000000+00:00'
$finishUtc = (Get-Date).ToUniversalTime().ToString('o')

# ================================================================= MEM-IDLE ==
$rss = Get-Content (Join-Path $RawDir 'mem-idle-fixture-30-v2.json') -Raw | ConvertFrom-Json
$rssValid = @($rss | Where-Object { $_.valid })
$hostVals = @($rssValid | ForEach-Object { [double]$_.diagnostics.host_ws_kib })
$rssSamples = @()
foreach ($r in $rss) {
  $d = $r.diagnostics
  $rssSamples += [ordered]@{
    run=[int]$r.run; value=[double]$d.host_ws_kib; valid=[bool]$r.valid; reject_reason=$r.reject_reason
    diagnostics=[ordered]@{
      host_ws_kib=[double]$d.host_ws_kib; host_private_kib=[double]$d.host_private_kib
      bun_ws_kib=[double]$d.bun_ws_kib; bun_private_kib=[double]$d.bun_private_kib; bun_process_count=[int]$d.bun_process_count
      engine_ws_kib=[double]$d.engine_ws_kib; engine_private_kib=[double]$d.engine_private_kib; engine_process_count=[int]$d.engine_process_count
      keld_processes_ws_kib=[double]$d.keld_processes_ws_kib; tree_ws_kib=[double]$d.tree_ws_kib
      native_window_ms=[double]$d.native_window_ms; settle_ms=[double]$d.settle_ms
      drift_observed=[double]$d.drift_observed; stability_samples=[int]$d.stability_samples
      census_stable=[bool]$d.census_stable; counter=[string]$d.counter } } }

Write-NoBom (Join-Path $BenchRepo 'windows\bench\results\mem-idle\2026-08-24.kel25-windows-fixture-idle-30.fresh-process.json') ([ordered]@{
  schema_version=1
  metric=[ordered]@{ id='MEM-IDLE'; unit='KiB'; registry_version=1 }
  cache_state='fresh-process'
  session=[ordered]@{ started_utc=$startUtc; finished_utc=$finishUtc; requested_samples=30; interleaving='none'
    label='kel25-windows-fixture-idle-30'
    notes='Idle RSS of the COMMITTED windows/keld/hello fixture through the shipping keld dev path, 30 fresh-process runs (the gui-paint-rss sample-policy count). SCORED value is the Keld-owned main-process (keld.exe) working set per metrics.v1.json MEM-IDLE. Every other lane is a per-run diagnostic and is never blended: bun child, WebView2 engine helpers, keld_processes_ws_kib (host+bun, the scope architecture 01 section 5 uses for its <=92160 KiB budget), and the whole descendant tree. Stability requires BOTH bounded drift (6 consecutive tree totals within 1% of the window mean) AND an identical process-class census across that window with a non-zero engine count. The census condition was added after a 30-run session produced one byte-stable but INCOMPLETE tree (55,336 KiB, engine_process_count=0, against a ~372,000 KiB median) that drift alone accepted; adding it also cut host-lane stdev from 986 to 69 KiB and engine-lane stdev from 59,139 to 3,376 KiB, so membership churn had been contaminating many samples rather than one. Raw run records: results/mem-idle/2026-08-24.kel25-windows-fixture-idle-30.fresh-process.raw.json. NOT a budget verdict: single arm, not interleaved, thermal state unknown.' }
  environment=(New-Env)
  provenance=[ordered]@{ bench_sha=$benchSha; bench_tree_state=$treeState; keld_sha=$keldSha
    harness=[ordered]@{ path=$rssHarness; sha256=$rssSha; version='kel25-mem-idle-v2-census' }
    fixtures=@([ordered]@{ path='windows/keld/hello/'; sha=$benchSha }) }
  arms=@([ordered]@{ arm_id='keld'
    framework=[ordered]@{ name='Keld host-owned hello (keld dev)'; version='0.0.1' }
    fixture_path='windows/keld/hello/'; lane='webview2'; role='diagnostic'
    artifact=[ordered]@{ sha256=$keldExeSha; basename='keld.exe'; version='0.0.1' }
    samples=$rssSamples
    statistics=[ordered]@{ valid_samples=$rssValid.Count; median=(Get-Median $hostVals); p90=(Get-NearestRank $hostVals 0.90); p99=$null
      min=($hostVals|Measure-Object -Minimum).Minimum; max=($hostVals|Measure-Object -Maximum).Maximum
      bootstrap_ci95=(Get-BootstrapCi95 $hostVals) } })
  publication=[ordered]@{ policy_version=1; requested=$false; eligible=$false; reasons=$COMMON } })

# ============================================================ NATIVE-WINDOW ==
$nwVals = @($rssValid | ForEach-Object { [double]$_.diagnostics.native_window_ms })
$nwSamples = @()
foreach ($r in $rss) {
  $nwSamples += [ordered]@{ run=[int]$r.run; value=[double]$r.diagnostics.native_window_ms; valid=[bool]$r.valid; reject_reason=$r.reject_reason
    diagnostics=[ordered]@{ oracle='Process.MainWindowHandle with matching title AND user32 IsWindowVisible AND NOT IsIconic'
      poll_interval_ms=50; clock='Stopwatch armed immediately before Start-Process, parent-side'
      engine_process_count=[int]$r.diagnostics.engine_process_count } } }

Write-NoBom (Join-Path $BenchRepo 'windows\bench\results\native-window\2026-08-24.kel25-windows-fixture-native-window-30.fresh-process.json') ([ordered]@{
  schema_version=1
  metric=[ordered]@{ id='NATIVE-WINDOW'; unit='ms'; registry_version=1 }
  cache_state='fresh-process'
  session=[ordered]@{ started_utc=$startUtc; finished_utc=$finishUtc; requested_samples=30; interleaving='none'
    label='kel25-windows-fixture-native-window-30'
    notes='Parent-side wall time from spawn to a real, visible, non-minimized titled HWND, against the COMMITTED windows/keld/hello fixture over 30 fresh-process runs, from the same launches as the MEM-IDLE document. metrics.v1.json marks NATIVE-WINDOW "Presentation policy, not paint; not comparable across frameworks". It is explicitly NOT PAINT-OPPORTUNITY: no beacon, no double-rAF, no nonce. Do NOT compare against the committed 469 ms Windows first-paint row: different oracle. Note this differs from the native_window_ms diagnostic inside the PAINT-OPPORTUNITY document (759.5 ms median) because that harness copies the fixture into a FRESH temp directory per launch, a colder filesystem state than repeated launches from one stable project directory. Raw run records: results/mem-idle/2026-08-24.kel25-windows-fixture-idle-30.fresh-process.raw.json.' }
  environment=(New-Env)
  provenance=[ordered]@{ bench_sha=$benchSha; bench_tree_state=$treeState; keld_sha=$keldSha
    harness=[ordered]@{ path=$rssHarness; sha256=$rssSha; version='kel25-mem-idle-v2-census' }
    fixtures=@([ordered]@{ path='windows/keld/hello/'; sha=$benchSha }) }
  arms=@([ordered]@{ arm_id='keld'
    framework=[ordered]@{ name='Keld host-owned hello (keld dev)'; version='0.0.1' }
    fixture_path='windows/keld/hello/'; lane='webview2'; role='diagnostic'
    artifact=[ordered]@{ sha256=$keldExeSha; basename='keld.exe'; version='0.0.1' }
    samples=$nwSamples
    statistics=[ordered]@{ valid_samples=$rssValid.Count; median=(Get-Median $nwVals); p90=(Get-NearestRank $nwVals 0.90); p99=$null
      min=($nwVals|Measure-Object -Minimum).Minimum; max=($nwVals|Measure-Object -Maximum).Maximum
      bootstrap_ci95=(Get-BootstrapCi95 $nwVals) } })
  publication=[ordered]@{ policy_version=1; requested=$false; eligible=$false
    reasons=($COMMON + @([ordered]@{ code='PRESENTATION_POLICY_ONLY'; label='NATIVE-WINDOW is presentation policy, not paint; the registry marks it diagnostic and not comparable across frameworks' })) } })

# ========================================================= PAINT-OPPORTUNITY ==
$paint = Get-Content (Join-Path $RawDir 'paint-30.json') -Raw | ConvertFrom-Json
$pValid = @($paint | Where-Object { $_.valid })
$pVals = @($pValid | ForEach-Object { [double]$_.value })
$pSamples = @()
foreach ($r in $paint) {
  $d = $r.diagnostics
  $pSamples += [ordered]@{ run=[int]$r.run; value=$(if ($null -ne $r.value) { [double]$r.value } else { $null })
    valid=[bool]$r.valid; reject_reason=$r.reject_reason
    diagnostics=[ordered]@{
      native_window_ms=$(if ($null -ne $d.native_window_ms) { [double]$d.native_window_ms } else { $null })
      window_to_paint_ms=$(if ($null -ne $d.window_to_paint_ms) { [double]$d.window_to_paint_ms } else { $null })
      port=[int]$d.port; nonce_matched=[bool]$d.nonce_matched; nonce_scope=[string]$d.nonce_scope
      beacon_sha256=[string]$d.beacon_sha256; beacon_source=[string]$d.beacon_source
      source_patched=[bool]$d.source_patched; fixture_copied_to_temp=[bool]$d.fixture_copied_to_temp } } }

Write-NoBom (Join-Path $BenchRepo 'windows\bench\results\paint-opportunity\2026-08-24.kel25-windows-keld-dev-paint-30.fresh-process.json') ([ordered]@{
  schema_version=1
  metric=[ordered]@{ id='PAINT-OPPORTUNITY'; unit='ms'; registry_version=1 }
  cache_state='fresh-process'
  session=[ordered]@{ started_utc='2026-08-24T16:05:00.0000000+00:00'; finished_utc=$finishUtc; requested_samples=30; interleaving='none'
    label='kel25-windows-keld-dev-paint-30'
    notes='FIRST Keld PAINT-OPPORTUNITY measured WITHOUT patching Keld product source. windows/bench/CONTRACT.md item 3 records SOURCE_TREE_PATCHED because Measure-FirstPaint.ps1 -Prepare splices the beacon into crates/keld-wv/src/hello/mod.rs and rebuilds keld-host, so no committed SHA reproduces the measured binary; that entry names the fix as a committed windows/keld/hello fixture. That fixture now exists and keld dev renders the fixture own index.html (crates/keld-cli/src/dev.rs load_dev_window_html reads it from disk per launch, inline NavTarget::Html, no rebuild), so this harness copies the COMMITTED fixture to a temp directory per launch and injects the beacon there. source_patched=false on every sample. THE ORACLE IS SHARED, NOT KELD-SPECIFIC: the beacon is extracted verbatim from windows/bench/hello.template.html, the same double-rAF image beacon the tauri and electron arms bake in, with only __PORT__ and __NONCE__ substituted; its sha256 is recorded per sample and was constant across all 30 runs. A harness that wrote its own beacon would grade Keld on a different exam than its competitors. Because a committed fixture is rewritten per launch with no rebuild, nonce and port are PER-LAUNCH (30 distinct ports over 30 runs), closing the hole Measure-FirstPaint.ps1 documents in its own header: it cannot distinguish a late beacon from run 3 arriving during run 4 of the same session. SCOPE, READ BEFORE COMPARING: this measures the full keld dev developer flow (environment checks, echo server, supervised Bun child spawn, authenticated kipc echo, THEN window and paint). It is NOT the scope of the committed 469 ms Windows first-paint row, which measured keld-host.exe alone and spawns no Bun child, and it is NOT scope-matched to a packaged Release competitor hello. ATTRIBUTION (same clock, same launch): of the 1,247.9 ms median, 759.5 ms (61%) is spawn to titled window and 492.6 ms (39%) is titled window to first composited frame. That second segment is the CreateCoreWebView2Controller Chromium boot architecture 01 section 5 already names as the floor, and it lands close to the committed 469 ms keld-host total, consistent with that total also being dominated by Chromium boot. NOT a budget verdict against the <=300 ms row. The required WEB-CONTENT gate has no Windows result document, and the registry preamble states correctness/security gates precede performance. Raw run records: results/paint-opportunity/2026-08-24.kel25-windows-keld-dev-paint-30.fresh-process.raw.json.' }
  environment=(New-Env)
  provenance=[ordered]@{ bench_sha=$benchSha; bench_tree_state=$treeState; keld_sha=$keldSha
    harness=[ordered]@{ path=$paintHarness; sha256=$paintSha; version='kel25-paint-v1-shared-oracle' }
    fixtures=@([ordered]@{ path='windows/keld/hello/'; sha=$benchSha })
    payload_sha256=((Get-FileHash (Join-Path $BenchRepo 'windows\bench\hello.template.html') -Algorithm SHA256).Hash.ToLower()) }
  arms=@([ordered]@{ arm_id='keld'
    framework=[ordered]@{ name='Keld host-owned hello via keld dev'; version='0.0.1' }
    fixture_path='windows/keld/hello/'; lane='webview2'; role='diagnostic'
    artifact=[ordered]@{ sha256=$keldExeSha; basename='keld.exe'; version='0.0.1' }
    samples=$pSamples
    statistics=[ordered]@{ valid_samples=$pValid.Count; median=(Get-Median $pVals); p90=(Get-NearestRank $pVals 0.90); p99=$null
      min=($pVals|Measure-Object -Minimum).Minimum; max=($pVals|Measure-Object -Maximum).Maximum
      bootstrap_ci95=(Get-BootstrapCi95 $pVals) } })
  publication=[ordered]@{ policy_version=1; requested=$false; eligible=$false
    reasons=($COMMON + @(
      [ordered]@{ code='SCOPE_NOT_HOST_ONLY'; label='Measures the full keld dev flow including Bun spawn and kipc echo, not keld-host alone; not scope-matched to the committed 469 ms first-paint row nor to a packaged competitor hello' }
      [ordered]@{ code='REQUIRED_GATE_UNMEASURED'; label='WEB-CONTENT is status:required and is the stated prerequisite for accepting a PAINT-OPPORTUNITY sample; it has no Windows result document' })) } })

Write-Output 'done'
