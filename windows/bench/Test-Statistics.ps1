<#
.SYNOPSIS
Unit and negative-control tests for Statistics.ps1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Statistics.ps1')

function Assert-Equal([double]$expected, [double]$actual, [string]$name) {
    if ($actual -ne $expected) {
        throw "$name expected $expected but got $actual"
    }
    Write-Host "  PASS  $name"
}

$odd = [double[]](1, 2, 3, 4, 100, 101, 102)
$even = [double[]](1, 2, 100, 101)

# Negative control: the deleted inline expression selects 100 for both inputs.
# The odd case specifically catches PowerShell's `[int]3.5 -> 4` banker's
# rounding; the even case catches upper-middle selection instead of averaging.
$legacyOdd = $odd[[int]($odd.Count / 2)]
$legacyEven = $even[[int]($even.Count / 2)]
if ($legacyOdd -eq 4 -or $legacyEven -eq 51) {
    throw 'legacy median-index negative control no longer represents the defect'
}
Write-Host "  PASS  legacy median index is falsified (odd=$legacyOdd, even=$legacyEven)"

Assert-Equal 4 (Get-Percentile -Values $odd -Percentile 0.5) 'odd-n median selects the middle observation'
Assert-Equal 51 (Get-Percentile -Values $even -Percentile 0.5) 'even-n median averages the middle observations'
Assert-Equal 9 (Get-Percentile -Values ([double[]](9)) -Percentile 0.5) 'single-value median is the sample'
Assert-Equal 1 (Get-Percentile -Values ([double[]](9, 1, 5)) -Percentile 0.0) 'p0 is the minimum'
Assert-Equal 9 (Get-Percentile -Values ([double[]](9, 1, 5)) -Percentile 1.0) 'p100 is the maximum'

Write-Host 'all statistic tests passed'
