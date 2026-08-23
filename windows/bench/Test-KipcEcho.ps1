<#
.SYNOPSIS
Negative controls for the KEL-99 Windows persistent kipc fixture.

.DESCRIPTION
Each control uses the live Keld host/Bun path. A harness that accepts either
case would be capable of reporting a plausible timing number for invalid IPC.
#>
[CmdletBinding()]
param(
    [string]$KeldRepo = 'D:\WORK\keld-kel-99-source',
    [string]$BenchRepo
)

$ErrorActionPreference = 'Stop'
if (-not $BenchRepo) { $BenchRepo = Join-Path $PSScriptRoot '..\..' }
$run = Join-Path $PSScriptRoot 'Run-KipcEcho.ps1'
$failures = 0

function Assert([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failures += 1 }
}

foreach ($fault in @('bad-token', 'wrong-response')) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $run -KeldRepo $KeldRepo -BenchRepo $BenchRepo -Fault $fault 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    Assert ($code -ne 0) "$fault exits nonzero" $text
    Assert ($text -match 'KELD-99-EXPECTED-FAIL:') "$fault emits the explicit client failure marker" $text
    Assert ($text -notmatch 'KEL-99 diagnostic complete:') "$fault cannot write a timing result" $text
}

if ($failures -gt 0) { exit 1 }
Write-Host 'all KEL-99 negative controls passed'
