param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string]$SignedHost,
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)][string]$TestBinary,
    [Parameter(Mandatory = $true)][string]$TestName,
    [int]$Runs = 1
)
# Runs one no_flag_windows cell from a prebuilt test binary (no compilation) against an
# operator-signed host; one log per run plus a tally line, and every host-printed
# KELD_TEST_WINDOWS_HANDOVER / KELD_KEL270_H* evidence line appended to samples.tsv.
# Exit code: number of failed runs. (S6c2a copy of the S6c1 run-h5.ps1 recipe.)
$ErrorActionPreference = 'Stop'
$evidence = '<evidence-dir>'
foreach ($path in @($SignedHost, $Installer, $TestBinary)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('missing: ' + $path) }
}
$dir = Join-Path $evidence ('runs/' + $Label)
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$env:KELD_KEL254_SIGNED_HOST_A_P1 = $SignedHost
$env:KELD_KEL254_INSTALLER_FIXTURE = $Installer
Remove-Item Env:KELD_DEV_LEASE -ErrorAction SilentlyContinue
$failed = 0
$savedPreference = $ErrorActionPreference
for ($run = 1; $run -le $Runs; $run += 1) {
    $log = Join-Path $dir ('run-' + $run.ToString('00') + '.log')
    $started = Get-Date
    try {
        $ErrorActionPreference = 'Continue'
        & $TestBinary $TestName --ignored --exact --nocapture --test-threads=1 > $log 2>&1
        $exit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
    $text = Get-Content -Raw -LiteralPath $log
    $outcome = if ($text -match '(?m)^test result: ok\. 1 passed') { 'PASS' } elseif ($text -match '(?m)^test result: .*1 failed') { 'FAIL' } else { 'UNKNOWN' }
    if ($exit -ne 0 -or $outcome -ne 'PASS') { $failed += 1 }
    $firstPanic = [regex]::Match($text, "(?m)^thread '[^']+' panicked at [^\r\n]*\r?\n([^\r\n]*)")
    $panicLine = if ($firstPanic.Success) { $firstPanic.Groups[1].Value } else { '' }
    Add-Content -LiteralPath (Join-Path $dir 'tally.txt') -Value ('run=' + $run + ' exit=' + $exit + ' outcome=' + $outcome + ' ms=' + $elapsed + ' panic=' + $panicLine)
    foreach ($line in [regex]::Matches($text, '(?m)^(KELD_TEST_WINDOWS_HANDOVER|KELD_KEL270_H\d+)[^\r\n]*')) {
        Add-Content -LiteralPath (Join-Path $dir 'samples.tsv') -Value ($run.ToString() + "`t" + $outcome + "`t" + $line.Value)
    }
    Write-Output ('CELL_RUN label=' + $Label + ' run=' + $run + ' exit=' + $exit + ' outcome=' + $outcome + ' ms=' + $elapsed + ' panic=' + $panicLine)
}
Write-Output ('CELL_TALLY label=' + $Label + ' runs=' + $Runs + ' failed=' + $failed)
exit $failed
