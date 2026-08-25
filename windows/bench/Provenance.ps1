# Shared provenance assertions for the document emitters.
#
# WHY THIS FILE EXISTS
# --------------------
# A published document records `provenance.harness.sha256` so a reader can
# recover the exact harness that produced the measurement from this repository.
# That claim only holds if the recorded hash is the hash of the BLOB at the
# recorded commit. Both emitters previously hashed the working-tree path
# instead, and one of them said so in its own doc comment -- "Hashing the
# working tree is what produced the false provenance this script exists to
# prevent" -- directly above four lines that wrote an unused temp file and then
# hashed the working tree anyway.
#
# It happened to agree today only because `.gitattributes` pins `*.ps1` to
# `text eol=lf`, so a Windows checkout under `core.autocrlf=true` is not
# rewritten. That is a hidden dependency on an attribute neither emitter reads:
# add one harness under a path without that attribute and the recorded hash
# silently stops being reproducible from the repository, which is the whole
# point of recording it.
#
# Hashing the blob makes the claim true by construction, for any file, under
# any attribute.
#
# Dot-source it, matching the existing `Statistics.ps1` convention:
#   . (Join-Path $PSScriptRoot 'Provenance.ps1')

function Get-GitBlobSha256 {
  <#
    .SYNOPSIS
      sha256 of the bytes git stores for $RepoRelPath at $Sha.

    .DESCRIPTION
      Streams `git cat-file blob` through SHA256 as raw bytes. PowerShell's own
      pipeline and redirection operators decode process output to text and
      re-encode it, so `git show ... | Out-File` cannot reproduce a blob hash;
      the stream has to be read from BaseStream.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Sha,
    [Parameter(Mandatory = $true)][string]$RepoRelPath
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = 'git'
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  # ProcessStartInfo.ArgumentList does not exist on .NET Framework 4.x, which is
  # what Windows PowerShell 5.1 runs on, so the argument string is built here.
  # Only $Repo can contain a space; $Sha and $RepoRelPath are git-shaped.
  $psi.Arguments = ('-C "{0}" cat-file blob {1}:{2}' -f $Repo, $Sha, $RepoRelPath)

  $proc = [System.Diagnostics.Process]::Start($psi)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $digest = $sha256.ComputeHash($proc.StandardOutput.BaseStream)
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
      throw "PROVENANCE FAILED: git cat-file blob ${Sha}:$RepoRelPath exited $($proc.ExitCode). $stderr"
    }
    return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLower()
  }
  finally {
    $sha256.Dispose()
    $proc.Dispose()
  }
}

function Assert-BlobAtCommit {
  <#
    .SYNOPSIS
      Asserts $RepoRelPath is committed at $Sha and unmodified, and returns the
      blob's sha256.

    .DESCRIPTION
      The modification check is `git diff --quiet $Sha -- $RepoRelPath`, which
      compares the working tree to that commit through the clean filter. The
      emitters previously used `git status --porcelain -- $path`, which compares
      against HEAD no matter which $Sha is passed, so the thrown message named a
      commit the check had not looked at.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Sha,
    [Parameter(Mandatory = $true)][string]$RepoRelPath
  )

  $null = & git -C $Repo cat-file -e "${Sha}:$RepoRelPath" 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "PROVENANCE FAILED: $RepoRelPath does not exist at $Sha. Commit it before emitting a document that cites it."
  }

  & git -C $Repo diff --quiet $Sha -- $RepoRelPath
  if ($LASTEXITCODE -ne 0) {
    throw "PROVENANCE FAILED: $RepoRelPath differs from its blob at $Sha (git diff exit $LASTEXITCODE). The document would name a harness that is not the one on disk."
  }

  return Get-GitBlobSha256 -Repo $Repo -Sha $Sha -RepoRelPath $RepoRelPath
}
