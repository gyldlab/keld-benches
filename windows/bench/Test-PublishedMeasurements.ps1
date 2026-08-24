<#
.SYNOPSIS
Negative control for Check-PublishedMeasurements.ps1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$check = Join-Path $PSScriptRoot 'Check-PublishedMeasurements.ps1'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$measurements = Join-Path $repoRoot 'MEASUREMENTS.md'

& $check -MeasurementsPath $measurements -BenchRoot $PSScriptRoot -RepoRoot $repoRoot

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("keld-measurements-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $temporary
    $temporaryMeasurements = Join-Path $temporary 'MEASUREMENTS.md'
    $text = [System.IO.File]::ReadAllText($measurements)
    $needle = '| Electron 43.4.0† <!-- raw-median source=windows-first-paint.json arm=electron fields=first_paint_ms,main_rss_kb,helper_rss_kb,processes --> | **372 ms** |'
    $replacement = '| Electron 43.4.0† <!-- raw-median source=windows-first-paint.json arm=electron fields=first_paint_ms,main_rss_kb,helper_rss_kb,processes --> | **999 ms** |'
    if (-not $text.Contains($needle)) {
        throw 'negative-control fixture row is missing from MEASUREMENTS.md'
    }
    [System.IO.File]::WriteAllText($temporaryMeasurements, $text.Replace($needle, $replacement))

    $rejected = $false
    try {
        & $check -MeasurementsPath $temporaryMeasurements -BenchRoot $PSScriptRoot -RepoRoot $repoRoot
    } catch {
        $rejected = $_.Exception.Message -match "field 'first_paint_ms' is 999"
    }
    if (-not $rejected) {
        throw 'publication checker accepted a table value that is not derivable from raw JSON'
    }
    Write-Host 'negative control passed: a mutated published median is rejected'

    $temporaryBench = Join-Path $temporary 'bench'
    $null = New-Item -ItemType Directory -Path $temporaryBench
    foreach ($source in @(
        'windows-first-paint.json',
        'windows-first-paint-kel65-direct-com.json',
        'windows-first-paint-kel65-baseline.json',
        'windows-first-paint-kel66-smartscreen-off.json'
    )) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $source) -Destination $temporaryBench
    }
    [System.IO.File]::AppendAllText(
        (Join-Path $temporaryBench 'windows-first-paint.json'),
        [Environment]::NewLine
    )

    $rejected = $false
    try {
        & $check -MeasurementsPath $measurements -BenchRoot $temporaryBench -RepoRoot $repoRoot
    } catch {
        $rejected = $_.Exception.Message -match "does not match immutable"
    }
    if (-not $rejected) {
        throw 'publication checker accepted a mutated historical raw source'
    }
    Write-Host 'negative control passed: a mutated historical raw source is rejected'
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
