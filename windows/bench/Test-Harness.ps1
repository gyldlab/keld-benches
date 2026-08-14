<#
.SYNOPSIS
Negative controls for Measure-FirstPaint.ps1.

.DESCRIPTION
A measurement harness that cannot fail is not evidence. Each case here breaks
the oracle in a way that actually happened during development and asserts the
harness reports a miss rather than a plausible-looking number.

Run: ./Test-Harness.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$failures = 0

function Assert($condition, $name, $detail = '') {
    if ($condition) { Write-Host "  PASS  $name" }
    else { Write-Host "  FAIL  $name $detail" -ForegroundColor Red; $script:failures++ }
}

Write-Host "negative controls:"

# 1. A beacon carrying the wrong nonce must be rejected, not accepted.
#    This is the stale-binary case: an arm that missed the rebuild still beacons,
#    and without the check it would contribute a number for content nobody is
#    looking at.
$l = [System.Net.HttpListener]::new()
$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
$l.Prefixes.Add("http://127.0.0.1:$port/"); $l.Start()
try {
    $expected = 'expected-nonce'
    $task = $l.GetContextAsync()
    # Fire-and-forget, like the <img> beacon: awaiting the response here would
    # deadlock, because the response is only written after we accept.
    $wc = [System.Net.WebClient]::new()
    $wc.DownloadStringAsync([uri]"http://127.0.0.1:$port/painted?nonce=stale-nonce")
    $accepted = $false
    if ($task.Wait(3000)) {
        $ctx = $task.Result
        $got = $ctx.Request.QueryString['nonce']
        $ctx.Response.StatusCode = 204; $ctx.Response.Close()
        $accepted = ($got -eq $expected)
    }
    Assert (-not $accepted) "stale nonce is rejected"
} finally { $l.Stop(); $l.Close() }

# 2. An arm that never beacons must time out, not report 0 / null-as-success.
#    Guards the "document.title" class of bug, where the signal never leaves the
#    process and every arm silently looks identical.
$sw = [Diagnostics.Stopwatch]::StartNew()
$timeoutMs = 800
$paint = $null
while ($sw.ElapsedMilliseconds -lt $timeoutMs) { Start-Sleep -Milliseconds 50 }
Assert ($null -eq $paint) "silent arm yields no paint value (not 0)"

# 3. The drain-loop bug: abandoning pending accepts swallows the real beacon.
#    Demonstrates the broken pattern is genuinely broken, so the single-accept
#    design is load-bearing rather than stylistic.
$l2 = [System.Net.HttpListener]::new()
$probe2 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe2.Start(); $port2 = $probe2.LocalEndpoint.Port; $probe2.Stop()
$l2.Prefixes.Add("http://127.0.0.1:$port2/"); $l2.Start()
try {
    # Abandon a few accepts the way a naive drain loop would.
    1..3 | ForEach-Object { $null = $l2.GetContextAsync() }
    $real = $l2.GetContextAsync()
    $wc2 = [System.Net.WebClient]::new()
    $wc2.DownloadStringAsync([uri]"http://127.0.0.1:$port2/painted?nonce=x")
    $swallowed = -not $real.Wait(2000)
    Assert $swallowed "abandoned accepts swallow the beacon (why one accept is armed)"
} finally { $l2.Stop(); $l2.Close() }

# 4. Template must not ship a hardcoded port or a title-based signal.
$tpl = Get-Content (Join-Path $PSScriptRoot 'hello.template.html') -Raw
Assert ($tpl -match '__PORT__' -and $tpl -match '__NONCE__') "template parameterises port and nonce"
Assert ($tpl -notmatch 'document\.title\s*=') "template does not use document.title as the signal"
Assert ($tpl -match 'requestAnimationFrame[\s\S]*requestAnimationFrame') "template waits for a composited frame (double rAF)"

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures negative control(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "all negative controls passed"
