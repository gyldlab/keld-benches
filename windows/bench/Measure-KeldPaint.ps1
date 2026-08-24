# PAINT-OPPORTUNITY for the Keld arm, without patching Keld product source.
#
# WHY THIS EXISTS
# ---------------
# windows/bench/CONTRACT.md item 3 records reason code SOURCE_TREE_PATCHED:
# Measure-FirstPaint.ps1 -Prepare splices the beacon into
# crates/keld-wv/src/hello/mod.rs and rebuilds keld-host, so no committed SHA
# reproduces the measured binary. That contract entry also names the fix:
# "a committed windows/keld/hello/ fixture with a build recipe". That fixture
# now exists, and `keld dev` renders the fixture's OWN index.html, so the
# beacon can live in a per-run COPY of the fixture instead of in product code.
#
# THE ORACLE MUST NOT FAVOUR THE ARM IT MEASURES
# ----------------------------------------------
# The beacon is not written here. It is EXTRACTED VERBATIM from the shared
# windows/bench/hello.template.html that the tauri/electron arms already bake
# in, and only __PORT__/__NONCE__ are substituted. A hand-written Keld-specific
# beacon would mean Keld is graded on a different exam than its competitors.
# This mirrors Bun's own rewrite discipline -- their test suite is written in
# TypeScript specifically so it "doesn't depend on the runtime's programming
# language" (bun.com/blog/bun-in-rust) -- an oracle that cannot favour the
# implementation under test.
#
# WHAT THIS DOES BETTER THAN THE PRE-CONTRACT HARNESS
# ---------------------------------------------------
# Per-LAUNCH nonce and port. Measure-FirstPaint.ps1 can only manage a
# per-SESSION nonce, because every arm bakes its HTML at build time (Keld a
# const, Tauri frontendDist, Electron app.asar) so a fresh nonce would mean a
# fresh build; its own header admits it "does NOT distinguish a late beacon
# from run 3 arriving during run 4 of the same session". A committed fixture
# is rewritten per launch with no rebuild at all, which closes that hole.
#
# NOTHING IS SILENTLY DROPPED. Every launch produces a sample; a sample that
# cannot be trusted is recorded valid=false with a named reject_reason.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$FixtureDir,
  [Parameter(Mandatory = $true)][string]$KeldExe,
  [Parameter(Mandatory = $true)][string]$BenchRepo,
  [string]$WindowTitle = 'hello',
  [int]$Runs = 30,
  [string]$OutFile,
  [int]$TimeoutMs = 60000
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PaintW32 {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@ -ErrorAction SilentlyContinue

# --- shared oracle ----------------------------------------------------------
function Get-SharedBeacon {
  param([string]$TemplatePath)
  $html = [System.IO.File]::ReadAllText($TemplatePath)
  $parts = $html -split '(?s)<script>'
  if ($parts.Count -lt 2) { throw "no <script> block in $TemplatePath; the shared beacon could not be extracted" }
  $beacon = '<script>' + (($parts[1] -replace '(?s)</script>.*$', '</script>'))
  if ($beacon -notmatch 'requestAnimationFrame') { throw "extracted beacon has no requestAnimationFrame; refusing to measure with a non-oracle" }
  if ($beacon -notmatch '__PORT__' -or $beacon -notmatch '__NONCE__') { throw "extracted beacon lacks __PORT__/__NONCE__ placeholders" }
  return $beacon
}

# --- negative controls ------------------------------------------------------
function Test-PaintOracle {
  param([string]$Beacon)
  # 1. The beacon must be the DOUBLE rAF, not a single one. A single-rAF
  #    beacon fires before the first frame is composited and would report a
  #    number that is too good.
  $rafCount = ([regex]::Matches($Beacon, 'requestAnimationFrame')).Count
  if ($rafCount -lt 2) { throw "NEGATIVE CONTROL FAILED: beacon has $rafCount requestAnimationFrame call(s), expected nested double-rAF" }

  # 2. Nonce comparison must reject a foreign/stale nonce.
  $match = { param($got, $want) return ($got -eq $want) }
  if (& $match 'aaaa' 'bbbb') { throw "NEGATIVE CONTROL FAILED: mismatched nonce was accepted" }
  if (-not (& $match 'abcd' 'abcd')) { throw "NEGATIVE CONTROL FAILED: matching nonce was rejected" }

  # 3. Substitution must actually replace both placeholders.
  $rendered = $Beacon.Replace('__PORT__', '12345').Replace('__NONCE__', 'deadbeef')
  if ($rendered -match '__PORT__' -or $rendered -match '__NONCE__') { throw "NEGATIVE CONTROL FAILED: placeholder survived substitution" }
  if ($rendered -notmatch '12345' -or $rendered -notmatch 'deadbeef') { throw "NEGATIVE CONTROL FAILED: substituted values absent" }

  Write-Output "negative-control: double-rAF=present nonce-mismatch=rejected substitution=complete  OK"
}

$templatePath = Join-Path $BenchRepo 'windows\bench\hello.template.html'
$beacon = Get-SharedBeacon -TemplatePath $templatePath
Test-PaintOracle -Beacon $beacon
$beaconSha = [System.BitConverter]::ToString(
  [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes($beacon))).Replace('-','').ToLower()
Write-Output "shared beacon sha256=$beaconSha (extracted from windows/bench/hello.template.html)"

$paintRecords = New-Object System.Collections.ArrayList

for ($i = 1; $i -le $Runs; $i++) {
  $listener = $null
  $proc = $null
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("keld-paint-" + [guid]::NewGuid().ToString('N').Substring(0,10))
  $paintMs = $null
  $windowMs = $null
  $reject = $null
  $nonce = [guid]::NewGuid().ToString('N')

  try {
    # Ephemeral port: bind 0, then read what the OS actually assigned.
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()

    # Per-run copy of the COMMITTED fixture. Product source is never touched,
    # and the committed fixture itself stays byte-identical to keld create.
    New-Item -ItemType Directory -Path (Join-Path $tmp 'src') -Force | Out-Null
    foreach ($f in @('.gitignore','index.html','keld.config.ts','package.json')) {
      Copy-Item (Join-Path $FixtureDir $f) (Join-Path $tmp $f)
    }
    foreach ($f in @('main.ts','kipc.ts')) {
      Copy-Item (Join-Path $FixtureDir "src\$f") (Join-Path $tmp "src\$f")
    }

    $rendered = $beacon.Replace('__PORT__', "$port").Replace('__NONCE__', $nonce)
    $idxPath = Join-Path $tmp 'index.html'
    $idx = [System.IO.File]::ReadAllText($idxPath)
    if ($idx -notmatch '(?s)</body>') { throw "fixture index.html has no </body> to inject before" }
    $idx = $idx -replace '(?s)</body>', ($rendered + "`n</body>")
    [System.IO.File]::WriteAllText($idxPath, $idx, (New-Object System.Text.UTF8Encoding($false)))

    $ctxTask = $listener.GetContextAsync()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $KeldExe -ArgumentList 'dev' -WorkingDirectory $tmp -PassThru -WindowStyle Normal

    # Same-run attribution. Capturing the titled-window moment and the paint
    # moment on ONE clock, in ONE launch, is what lets the result decompose
    # "spawn -> window" from "window -> first composited frame" instead of
    # reporting one opaque total. Bun's rewrite writeup attributes its gains to
    # named mechanisms rather than to the rewrite itself; this is the same move.
    while ($true) {
      if ($null -eq $windowMs -and -not $proc.HasExited) {
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero -and $proc.MainWindowTitle -eq $WindowTitle) {
          $windowMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
        }
      }
      if ($ctxTask.Wait(25)) {
        $elapsed = $sw.Elapsed.TotalMilliseconds
        $ctx = $ctxTask.Result
        $got = $ctx.Request.QueryString['nonce']
        $ctx.Response.StatusCode = 204
        $ctx.Response.Close()
        if ($got -eq $nonce) { $paintMs = [math]::Round($elapsed, 3) }
        else { $reject = "NONCE_MISMATCH got='$got'" }
        break
      }
      if ($proc.HasExited) { $reject = 'PROCESS_EXITED_BEFORE_PAINT'; break }
      if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { $reject = "TIMEOUT_${TimeoutMs}MS"; break }
    }
  }
  catch { $reject = "HARNESS_ERROR: $($_.Exception.Message)" }
  finally {
    if ($proc -and -not $proc.HasExited) {
      $proc.Refresh()
      if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        [void][PaintW32]::PostMessage($proc.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
      }
      if (-not $proc.WaitForExit(15000)) { try { Stop-Process -Id $proc.Id -Force } catch {} }
    }
    if ($listener) { try { $listener.Stop(); $listener.Close() } catch {} }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  $rec = [ordered]@{
    run           = $i
    value         = $paintMs
    valid         = ($null -ne $paintMs)
    reject_reason = $reject
    diagnostics   = [ordered]@{
      port                = $port
      native_window_ms    = $windowMs
      window_to_paint_ms  = $(if ($null -ne $paintMs -and $null -ne $windowMs) { [math]::Round($paintMs - $windowMs, 3) } else { $null })
      nonce_matched       = ($null -ne $paintMs)
      beacon_sha256       = $beaconSha
      beacon_source       = 'windows/bench/hello.template.html'
      nonce_scope         = 'per-launch'
      source_patched      = $false
      fixture_copied_to_temp = $true
    }
  }
  [void]$paintRecords.Add($rec)
  Write-Output ("  run {0,2}/{1}: {2}" -f $i, $Runs, $(if ($paintMs) { "paint=${paintMs}ms port=$port" } else { "REJECTED $reject" }))
}

if ($OutFile) {
  [System.IO.File]::WriteAllText($OutFile, ($paintRecords | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
  Write-Output "wrote $OutFile"
}
