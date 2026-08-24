<#
.SYNOPSIS
Checks that raw-bound median rows in MEASUREMENTS.md match committed JSON.

.DESCRIPTION
Rows covered by this check carry an inline `raw-median` marker that names one
committed raw file, arm, and ordered list of numeric fields. Values are derived
with the same percentile helper used by Measure-FirstPaint.ps1. The marker has
no expected number, so editing a raw file or a published cell cannot make the
check self-consistently pass.

Run from the repository root:
  pwsh -NoProfile -File windows/bench/Check-PublishedMeasurements.ps1
#>
[CmdletBinding()]
param(
    [string]$MeasurementsPath = (Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'MEASUREMENTS.md'),
    [string]$BenchRoot = $PSScriptRoot,
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Statistics.ps1')

if (-not $RepoRoot) {
    $RepoRoot = Split-Path (Split-Path $BenchRoot -Parent) -Parent
}

# These are the immutable authorities for the historical publications. The
# commit proves provenance, the Git blob binds the repo path at that commit,
# and SHA-256 rejects a changed working-tree copy before it can feed a table.
$publishedSources = @{
    'windows-first-paint.json' = @{
        Commit = '39bab061951283901023a34e885de41d432e3483'
        GitBlob = '683d485b45947f2c4ce9c02bef61bccc795f0280'
        Sha256 = '0b57f6dfe8dc0b47c3625943ebf2c2985a59b6fe8e07a2ca9eada4729253b358'
    }
    'windows-first-paint-kel65-direct-com.json' = @{
        Commit = '686d1ab632f023488227fcb5e7b44009df899653'
        GitBlob = '4ce3b9a1445714146e0ec3b370cb7591e64c3d50'
        Sha256 = '231fcf1696b8e6a8b50c67ba2a49ad6648691ba743cf0fff05a32e3efde40630'
    }
    'windows-first-paint-kel65-baseline.json' = @{
        Commit = '686d1ab632f023488227fcb5e7b44009df899653'
        GitBlob = 'ce418d5674267c932532e2854e75aeb1477bfc94'
        Sha256 = 'b8626526009ed52a5dde828c926043c430825b2fc7a1e23f30a2019260dcbfee'
    }
    'windows-first-paint-kel66-smartscreen-off.json' = @{
        Commit = '686d1ab632f023488227fcb5e7b44009df899653'
        GitBlob = '23a52cccf05c65cc6731dfdcd7c35fbba0c4355d'
        Sha256 = '5257e5bfbba11a8194f89b3a0260bcccf58f025fd5c9465cb672e483fb880328'
    }
}
$validatedSources = @{}

function Assert-ImmutableRawSource([string]$source, [string]$rawPath) {
    if (-not $publishedSources.ContainsKey($source)) {
        throw "raw-median source '$source' is not an allowlisted immutable publication source"
    }
    if ($validatedSources.ContainsKey($source)) { return }

    $authority = $publishedSources[$source]
    $relativePath = "windows/bench/$source"
    $gitObject = "$($authority.Commit):$relativePath"
    $resolvedBlob = (& git -C $RepoRoot rev-parse $gitObject 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "cannot resolve immutable publication source '$gitObject'; fetch repository history and rerun"
    }
    if ($resolvedBlob -ne $authority.GitBlob) {
        throw "immutable publication source '$gitObject' resolved to unexpected Git blob '$resolvedBlob'"
    }

    $workingHash = (Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($workingHash -ne $authority.Sha256) {
        throw "working raw '$source' does not match immutable $($authority.Commit):$relativePath"
    }
    $validatedSources[$source] = $true
}

function Get-PublishedNumber([string]$cell, [string]$publication) {
    $withoutMarker = $cell -replace '<!--.*?-->', ''
    $matches = [regex]::Matches($withoutMarker, '-?\d[\d,]*(?:\.\d+)?')
    if ($matches.Count -ne 1) {
        throw "$publication must contain exactly one numeric value per raw-bound cell; got '$cell'"
    }
    $number = $matches[0].Value.Replace(',', '')
    return [double]::Parse($number, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-RawFieldValues([object[]]$samples, [string]$field, [string]$publication) {
    if ($field -eq 'processes') {
        $values = @($samples | ForEach-Object { [double]$_.processes } | Sort-Object -Unique)
        if ($values.Count -ne 1) {
            throw "$publication cannot publish one process count because the raw samples disagree"
        }
        return $values
    }

    $values = @($samples | ForEach-Object {
        $property = $_.PSObject.Properties[$field]
        if ($null -eq $property -or $null -eq $property.Value) {
            throw "$publication raw sample has no numeric '$field' value"
        }
        [double]$property.Value
    })
    return $values
}

if (-not (Test-Path -LiteralPath $MeasurementsPath -PathType Leaf)) {
    throw "missing measurements document: $MeasurementsPath"
}

$resolvedMeasurements = (Resolve-Path -LiteralPath $MeasurementsPath).Path
$lines = [System.IO.File]::ReadAllLines($resolvedMeasurements)
$markerPattern = '<!--\s*raw-median\s+source=(?<source>\S+)\s+arm=(?<arm>[a-z0-9-]+)\s+fields=(?<fields>[a-z0-9_,]+)\s*-->'
$checkedRows = 0

foreach ($line in $lines) {
    $marker = [regex]::Match($line, $markerPattern)
    if (-not $marker.Success) { continue }

    $source = $marker.Groups['source'].Value
    $arm = $marker.Groups['arm'].Value
    $fields = @($marker.Groups['fields'].Value.Split(','))
    $publication = "$source arm '$arm'"
    $rawPath = Join-Path $BenchRoot $source
    if (-not (Test-Path -LiteralPath $rawPath -PathType Leaf)) {
        throw "$publication names missing raw file '$rawPath'"
    }
    Assert-ImmutableRawSource $source $rawPath

    $raw = Get-Content -LiteralPath $rawPath -Raw | ConvertFrom-Json
    $samples = @($raw.samples | Where-Object {
        $_.arm -eq $arm -and $null -ne $_.first_paint_ms
    })
    if ($samples.Count -eq 0) {
        throw "$publication has no valid raw samples"
    }

    $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    if ($cells.Count -ne ($fields.Count + 1)) {
        throw "$publication row has $($cells.Count - 1) numeric cells; marker declares $($fields.Count)"
    }

    for ($index = 0; $index -lt $fields.Count; $index++) {
        $field = $fields[$index]
        $values = Get-RawFieldValues $samples $field $publication
        $expected = if ($field -eq 'processes') {
            $values[0]
        } else {
            Get-Percentile -Values $values -Percentile 0.5
        }
        $actual = Get-PublishedNumber $cells[$index + 1] $publication
        if ($actual -ne $expected) {
            throw "$publication field '$field' is $actual but committed raw median is $expected"
        }
    }
    $checkedRows++
}

if ($checkedRows -eq 0) {
    throw 'MEASUREMENTS.md contains no raw-median publication markers'
}

Write-Host "published-measurement check passed: $checkedRows raw-bound median rows"
