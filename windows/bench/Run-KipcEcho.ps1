<#
.SYNOPSIS
Run the KEL-99 Windows Bun-to-Rust authenticated persistent kipc echo diagnostic.

.DESCRIPTION
Builds an isolated Release runner that reuses Keld's HostOwnedHelloSession,
copies the selected Keld revision's wire-exact Bun client template, and writes
one immutable result.v1 summary plus a sibling raw JSON document. A run has
exactly 10,000 sequential CALL/REPLY observations after one authenticated
HELLO; no synthetic loopback timer exists in this harness.

The output is deliberately publication-ineligible until the registered IPC
sample policy (20 sessions x 100,000 calls, paired arms and block bootstrap) is
met. It is performance evidence for the current Windows product slice, not an
optimisation mechanism or a budget verdict.
#>
[CmdletBinding()]
param(
    [ValidateSet('fresh-process', 'warm-cache')]
    [string]$CacheState = 'fresh-process',
    [string]$KeldRepo = 'D:\WORK\keld-kel-99-source',
    [string]$BenchRepo,
    [string]$OutFile,
    [ValidateSet('none', 'bad-token', 'wrong-response')]
    [string]$Fault = 'none'
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$fixtureRoot = Join-Path $PSScriptRoot '..\keld\kipc-echo'
if (-not $BenchRepo) { $BenchRepo = Join-Path $PSScriptRoot '..\..' }
$BenchRepo = (Resolve-Path $BenchRepo).Path
$KeldRepo = (Resolve-Path $KeldRepo).Path
$fixtureRoot = (Resolve-Path $fixtureRoot).Path

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Invoke-Native([string]$File, [string[]]$Arguments, [string]$Label) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $File @Arguments
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) { throw "$Label failed (exit $code)" }
}

function Get-Git([string]$Repo, [string[]]$Arguments) {
    $value = & git -C $Repo @Arguments
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed for benchmark provenance" }
    ($value -join "`n").Trim()
}

function Get-PackageVersion([object]$Metadata, [string]$Name) {
    $package = @($Metadata.packages | Where-Object { $_.name -eq $Name })
    if ($package.Count -ne 1) { throw "cargo metadata did not resolve exactly one $Name package" }
    [string]$package[0].version
}

function Get-PercentileNs([long[]]$Sorted, [double]$Percentile) {
    if ($Sorted.Count -eq 0) { throw 'cannot calculate a percentile from zero calls' }
    $rank = [int][Math]::Ceiling($Percentile * $Sorted.Count)
    $Sorted[$rank - 1]
}

function Test-ResultV1([string]$SchemaPath, [string]$ResultPath) {
    $program = @'
import json
import sys
from jsonschema import Draft202012Validator

with open(sys.argv[1], encoding="utf-8") as schema_file:
    schema = json.load(schema_file)
with open(sys.argv[2], encoding="utf-8") as result_file:
    result = json.load(result_file)
errors = sorted(Draft202012Validator(schema).iter_errors(result), key=lambda error: error.json_path)
if errors:
    raise SystemExit(f"result.v1 validation failed at {errors[0].json_path}: {errors[0].message}")
'@
    Invoke-Native 'python' @('-c', $program, $SchemaPath, $ResultPath) 'result.v1 validation'
}

function Remove-TempWorktree([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = [IO.Path]::GetFullPath($Path)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to remove non-temporary benchmark path $full"
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}

function Invoke-Runner([string]$Runner, [string]$Project, [string]$Mode, [string]$FaultMode) {
    $previousProject = $env:KELD_BENCH_PROJECT
    $previousMode = $env:KELD_BENCH_MODE
    $previousFault = $env:KELD_BENCH_FAULT
    $env:KELD_BENCH_PROJECT = $Project
    $env:KELD_BENCH_MODE = $Mode
    $env:KELD_BENCH_FAULT = $FaultMode
    try {
        # A deliberate negative control exits non-zero after emitting its marker.
        # Keep that native status observable so callers can prove the marker before
        # deciding whether the run is valid; `Stop` would throw before capture.
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $lines = & $Runner 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }
        return [pscustomobject]@{ ExitCode = $code; Text = (($lines | ForEach-Object { $_.ToString() }) -join "`n") }
    }
    finally {
        $env:KELD_BENCH_PROJECT = $previousProject
        $env:KELD_BENCH_MODE = $previousMode
        $env:KELD_BENCH_FAULT = $previousFault
    }
}

function New-RunnerManifest([string]$Path, [string]$SourceRoot) {
    $normalized = $SourceRoot.Replace('\', '/')
    @"
[package]
name = "keld-kel99-runner"
version = "0.1.0"
edition = "2024"
publish = false

[workspace]

[dependencies]
keld-core = { path = "$normalized/crates/keld-core" }
keld-runtime = { path = "$normalized/crates/keld-runtime" }
"@ | ForEach-Object { Write-Utf8NoBom $Path $_ }
}

if ((Get-Git $BenchRepo @('status', '--porcelain')).Length -ne 0) {
    throw 'keld-benches must be clean before timing; commit or remove unrelated changes first'
}
if ((Get-Git $KeldRepo @('status', '--porcelain')).Length -ne 0) {
    throw 'Keld source must be clean before timing; use an immutable clean worktree'
}
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { throw 'bun is required on PATH' }
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw 'cargo is required on PATH' }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw 'python is required to validate result.v1 output' }

$benchSha = Get-Git $BenchRepo @('rev-parse', 'HEAD')
$keldSha = Get-Git $KeldRepo @('rev-parse', 'HEAD')
$harnessPath = Join-Path $PSScriptRoot 'Run-KipcEcho.ps1'
$templatePath = Join-Path $KeldRepo 'crates\keld-cli\templates\hello\src\kipc.ts'
$runnerSourcePath = Join-Path $fixtureRoot 'runner.rs'
$mainSourcePath = Join-Path $fixtureRoot 'main.ts'
foreach ($required in @($harnessPath, $templatePath, $runnerSourcePath, $mainSourcePath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "required fixture source is missing: $required" }
}

$metadataText = (& cargo metadata --format-version 1 --no-deps --manifest-path (Join-Path $KeldRepo 'Cargo.toml')) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'cargo metadata failed' }
$metadata = $metadataText | ConvertFrom-Json
$coreVersion = Get-PackageVersion $metadata 'keld-core'
$hostVersion = Get-PackageVersion $metadata 'keld-host'
$cliVersion = Get-PackageVersion $metadata 'keld-cli'
$bunCommand = Get-Command bun
$bunVersion = ((& bun --version) -join "`n").Trim()
if ($LASTEXITCODE -ne 0) { throw 'bun --version failed' }
$rustcVersion = ((& rustc -Vv) -join "`n").Trim()
if ($LASTEXITCODE -ne 0) { throw 'rustc -Vv failed' }

$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if (-not $os -or -not $cpu) { throw 'Windows OS/CPU metadata is required for a benchmark result' }
$battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
if ($battery.Count -eq 0) { throw 'cannot determine AC power on this machine; refusing to fabricate a power condition' }
$acPower = @('2', '6', '7', '8', '9') -contains [string]$battery[0].BatteryStatus
$powerPlan = ((& powercfg /GetActiveScheme) -join " `n").Trim()
if ($LASTEXITCODE -ne 0) { throw 'powercfg /GetActiveScheme failed' }
$lowPowerMode = $powerPlan -match '(?i)power saver'

$mode = if ($CacheState -eq 'warm-cache') { 'warm' } else { 'cold' }
$date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$label = "kel99-windows-bun-10k-$mode"
$resultDir = Join-Path $PSScriptRoot 'results\ipc-rtt'
if (-not $OutFile) { $OutFile = Join-Path $resultDir "$date.$label.$CacheState.json" }
$OutFile = [IO.Path]::GetFullPath($OutFile)
$resultRoot = [IO.Path]::GetFullPath($resultDir)
if (-not $OutFile.StartsWith($resultRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "benchmark output must stay under $resultRoot"
}
$rawFile = $OutFile -replace '\.json$', '.raw.json'
if ((Test-Path -LiteralPath $OutFile) -or (Test-Path -LiteralPath $rawFile)) {
    throw "refusing to overwrite immutable benchmark output $OutFile"
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("keld-kel99-" + [Guid]::NewGuid().ToString('N'))
$started = [DateTimeOffset]::UtcNow
try {
    $project = Join-Path $work 'project'
    $runnerPackage = Join-Path $work 'runner'
    $target = Join-Path $work 'target'
    New-Item -ItemType Directory -Force -Path (Join-Path $project 'src'), (Join-Path $runnerPackage 'src'), $target | Out-Null
    Copy-Item -LiteralPath $templatePath -Destination (Join-Path $project 'src\kipc.ts')
    Copy-Item -LiteralPath $mainSourcePath -Destination (Join-Path $project 'src\main.ts')
    Write-Utf8NoBom (Join-Path $project 'keld.config.ts') "export default { name: 'KEL-99 IPC diagnostic', renderer: 'index.html' };`n"
    Write-Utf8NoBom (Join-Path $project 'index.html') '<!doctype html><title>KEL-99</title>'
    Copy-Item -LiteralPath $runnerSourcePath -Destination (Join-Path $runnerPackage 'src\main.rs')
    New-RunnerManifest (Join-Path $runnerPackage 'Cargo.toml') $KeldRepo

    $previousTarget = $env:CARGO_TARGET_DIR
    $env:CARGO_TARGET_DIR = $target
    try {
        Invoke-Native 'cargo' @('build', '--release', '--manifest-path', (Join-Path $runnerPackage 'Cargo.toml')) 'KEL-99 Release runner build'
    }
    finally {
        $env:CARGO_TARGET_DIR = $previousTarget
    }
    $runner = Join-Path $target 'release\keld-kel99-runner.exe'
    if (-not (Test-Path -LiteralPath $runner)) { throw "Release runner was not produced at $runner" }

    if ($Fault -ne 'none') {
        $negative = Invoke-Runner $runner $project $mode $Fault
        if ($negative.ExitCode -eq 0 -or $negative.Text -notmatch 'KELD-99-EXPECTED-FAIL:') {
            throw "negative control $Fault was not rejected by the live fixture: $($negative.Text)"
        }
        Write-Output $negative.Text
        throw "negative control $Fault correctly rejected; no benchmark result was written"
    }

    if ($CacheState -eq 'warm-cache') {
        $priming = Invoke-Runner $runner $project 'warm' 'none'
        if ($priming.ExitCode -ne 0 -or $priming.Text -notmatch 'KELD-99-RESULT:') {
            throw "unscored warm-cache priming pair failed: $($priming.Text)"
        }
    }

    $run = Invoke-Runner $runner $project $mode 'none'
    if ($run.ExitCode -ne 0) { throw "live 10k session failed: $($run.Text)" }
    $resultLines = @($run.Text -split "`r?`n" | Where-Object { $_.StartsWith('KELD-99-RESULT:') })
    if ($resultLines.Count -ne 1) { throw "expected one KELD-99 result line, observed $($resultLines.Count)" }
    $client = ($resultLines[0].Substring('KELD-99-RESULT:'.Length) | ConvertFrom-Json)
    if ($client.calls -ne 10000 -or $client.deltas_ns.Count -ne 10000) { throw 'client did not report exactly 10,000 timed calls' }
    if ($client.clock -ne 'Bun.nanoseconds') { throw "unexpected client clock $($client.clock)" }
    if ($client.mode -ne $mode) { throw "client mode $($client.mode) did not match requested mode $mode" }
    if ($client.encoded_request_bytes -gt 128 -or $client.encoded_request_bytes -ne $client.encoded_reply_bytes) {
        throw 'client request/reply payload shape was not bounded and symmetric'
    }

    [long[]]$sorted = @($client.deltas_ns | ForEach-Object { [long]$_ } | Sort-Object)
    if ($sorted | Where-Object { $_ -lt 0 }) { throw 'negative RTT duration in client result' }
    $p50Ns = Get-PercentileNs $sorted 0.50
    $p90Ns = Get-PercentileNs $sorted 0.90
    $p99Ns = Get-PercentileNs $sorted 0.99
    $finished = [DateTimeOffset]::UtcNow
    $relativeResult = "windows/bench/results/ipc-rtt/$([IO.Path]::GetFileName($OutFile))"
    $relativeRaw = "windows/bench/results/ipc-rtt/$([IO.Path]::GetFileName($rawFile))"

    $raw = [ordered]@{
        schema_version = 'keld99-ipc-rtt-raw-v1'
        metric = 'IPC-RTT'
        cache_state = $CacheState
        session = [ordered]@{
            started_utc = $started.ToString('o')
            finished_utc = $finished.ToString('o')
            mode = $mode
            priming_process_pair = ($CacheState -eq 'warm-cache')
            calls = 10000
            warmup_calls = [int]$client.warmup_calls
            timer = [ordered]@{
                name = 'Bun.nanoseconds'
                start = 'immediately before await session.echo(request)'
                stop = 'after echoed Reply decode and equality validation'
                handshake = 'one AppLinkSession.connect mutual HELLO; excluded from RTT'
            }
        }
        product_slice = [ordered]@{
            host = 'keld_core::HostOwnedHelloSession (same primitive used by keld dev and run_dev_echo)'
            transport = 'Windows v0 loopback TCP 127.0.0.1:0'
            authentication = 'host-minted 32-byte KELD_APP_LINK token in kipc v2 HELLO'
            client = 'current keld-cli hello template kipc.ts copied by hash into isolated project'
            request = $client.request
            encoded_request_bytes = [int]$client.encoded_request_bytes
            encoded_reply_bytes = [int]$client.encoded_reply_bytes
            frame_header_bytes = [int]$client.frame_header_bytes
        }
        versions = [ordered]@{
            keld_core = $coreVersion
            keld_host = $hostVersion
            keld_cli = $cliVersion
            bun = $bunVersion
            rustc = $rustcVersion
        }
        provenance = [ordered]@{
            bench_sha = $benchSha
            keld_sha = $keldSha
            harness_sha256 = (Get-Sha256 $harnessPath)
            runner_source_sha256 = (Get-Sha256 $runnerSourcePath)
            runner_artifact_sha256 = (Get-Sha256 $runner)
            client_template_sha256 = (Get-Sha256 $templatePath)
            bun_executable_sha256 = (Get-Sha256 $bunCommand.Source)
        }
        environment = [ordered]@{
            os = $os.Caption
            os_version = $os.Version
            os_build = $os.BuildNumber
            cpu = $cpu.Name.Trim()
            arch = $env:PROCESSOR_ARCHITECTURE
            ram_bytes = [int64]$os.TotalVisibleMemorySize * 1KB
            ac_power = $acPower
            power_scheme = $powerPlan
            low_power_mode = $lowPowerMode
            thermal_state = 'unknown'
        }
        statistics_ns = [ordered]@{
            calls = 10000
            min = $sorted[0]
            p50 = $p50Ns
            p90 = $p90Ns
            p99 = $p99Ns
            max = $sorted[$sorted.Count - 1]
        }
        deltas_ns = @($client.deltas_ns | ForEach-Object { [long]$_ })
        limitations = @(
            'One 10,000-call Bun session only; registry publication policy requires >=20 sessions and 100,000 calls/session.',
            'No Rust-client comparison, paired block bootstrap, allocation counter, syscall attribution, throughput arm, or cross-OS comparison.',
            'Windows v0 transport is loopback TCP, not the destination named-pipe/DACL transport.',
            'Thermal state has no verified unprivileged Windows oracle in this fixture.'
        )
    }
    $summary = [ordered]@{
        schema_version = 1
        metric = [ordered]@{ id = 'IPC-RTT'; unit = 'us'; registry_version = 1 }
        cache_state = $CacheState
        session = [ordered]@{
            started_utc = $started.ToString('o')
            finished_utc = $finished.ToString('o')
            requested_samples = 1
            interleaving = 'none'
            label = $label
            notes = "One authenticated Bun session, exactly 10,000 sequential typed CALL/REPLY pairs. Raw values are $relativeRaw; p50/p90/p99 in this one session are diagnostic only."
        }
        environment = [ordered]@{
            os = [ordered]@{ name = 'windows'; version = $os.Caption; build = $os.Version }
            hardware = [ordered]@{ cpu = $cpu.Name.Trim(); arch = $env:PROCESSOR_ARCHITECTURE; ram_bytes = [int64]$os.TotalVisibleMemorySize * 1KB; machine_label = 'windows-local-2026-08-23' }
            power = [ordered]@{ ac_power = $acPower; low_power_mode = $lowPowerMode; thermal_state = 'unknown' }
            toolchains = @(
                [ordered]@{ name = 'rustc'; version = $rustcVersion },
                [ordered]@{ name = 'bun'; version = $bunVersion },
                [ordered]@{ name = 'keld-host'; version = $hostVersion },
                [ordered]@{ name = 'keld-cli'; version = $cliVersion }
            )
        }
        provenance = [ordered]@{
            bench_sha = $benchSha
            bench_tree_state = 'clean'
            keld_sha = $keldSha
            harness = [ordered]@{ path = 'windows/bench/Run-KipcEcho.ps1'; sha256 = (Get-Sha256 $harnessPath); version = 'kel99-ipc-rtt-v1' }
            fixtures = @([ordered]@{ path = 'windows/keld/kipc-echo'; sha = $benchSha })
        }
        arms = @(
            [ordered]@{
                arm_id = 'keld-bun'
                framework = [ordered]@{ name = 'Keld host-owned kipc + Bun'; version = $coreVersion }
                fixture_path = 'windows/keld/kipc-echo'
                role = 'diagnostic'
                artifact = [ordered]@{ sha256 = (Get-Sha256 $runner); basename = 'keld-kel99-runner.exe'; version = $hostVersion }
                samples = @(
                    [ordered]@{
                        run = 1
                        value = [double]$p99Ns / 1000.0
                        valid = $true
                        reject_reason = $null
                        diagnostics = [ordered]@{
                            mode = $mode
                            calls = 10000
                            warmup_calls = [int]$client.warmup_calls
                            p50_ns = $p50Ns
                            p90_ns = $p90Ns
                            p99_ns = $p99Ns
                            min_ns = $sorted[0]
                            max_ns = $sorted[$sorted.Count - 1]
                            encoded_request_bytes = [int]$client.encoded_request_bytes
                            encoded_reply_bytes = [int]$client.encoded_reply_bytes
                            raw_output = $relativeRaw
                            timer = 'Bun.nanoseconds around session.echo'
                        }
                    }
                )
                statistics = [ordered]@{ valid_samples = 1; median = [double]$p99Ns / 1000.0; p90 = $null; p99 = $null; min = [double]$p99Ns / 1000.0; max = [double]$p99Ns / 1000.0 }
            }
        )
        publication = [ordered]@{
            policy_version = 1
            requested = $false
            eligible = $false
            reasons = @(
                [ordered]@{ code = 'SAMPLES_BELOW_POLICY'; label = '1 independent session; IPC policy requires at least 20' },
                [ordered]@{ code = 'CALLS_BELOW_POLICY'; label = '10,000 calls; IPC policy requires 100,000 calls per session' },
                [ordered]@{ code = 'NO_PAIRED_ARM'; label = 'Bun-only diagnostic has no paired Rust arm' },
                [ordered]@{ code = 'NO_BLOCK_BOOTSTRAP_CI'; label = 'No required session-block bootstrap confidence intervals' },
                [ordered]@{ code = 'THERMAL_STATE_UNVERIFIED'; label = 'Windows thermal state is recorded as unknown' }
            )
        }
    }
    Write-Utf8NoBom $rawFile ($raw | ConvertTo-Json -Depth 16)
    Write-Utf8NoBom $OutFile ($summary | ConvertTo-Json -Depth 16)
    Invoke-Native 'python' @((Join-Path $BenchRepo 'schema\check.py')) 'result schema contract check'
    Test-ResultV1 (Join-Path $BenchRepo 'schema\result.v1.schema.json') $OutFile
    $resultText = Get-Content -Raw -LiteralPath $OutFile | ConvertFrom-Json
    if ($resultText.metric.id -ne 'IPC-RTT' -or $resultText.publication.eligible) { throw 'result summary semantic validation failed' }
    Write-Host "KEL-99 diagnostic complete: $relativeResult"
    Write-Host "raw output: $relativeRaw"
    Write-Host ("p50={0:N3} us p99={1:N3} us ({2} calls; publication ineligible)" -f ([double]$p50Ns / 1000.0), ([double]$p99Ns / 1000.0), $sorted.Count)
}
finally {
    Remove-TempWorktree $work
}
