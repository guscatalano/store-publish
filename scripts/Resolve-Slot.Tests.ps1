<#
  Does the slot decision actually hold?
  Run: pwsh -NoProfile -File scripts/Resolve-Slot.Tests.ps1

  This pipeline had no tests at all, and the cost showed: the code that
  decided whether a submission was pending read the exit code of `msstore
  submission get`, which is 0 even when nothing is pending - it falls back
  to the last PUBLISHED submission and hands that back instead. A published
  release read as a draft in progress. Nothing catches that but a test.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Resolve-Slot.ps1'
$failed = 0

# Takes the call as a scriptblock, not its result: a case that throws when it
# was meant to return has to be reported as that one failure and the rest of
# the suite still run. Passed a value instead, an unexpected throw is raised
# while the arguments are being evaluated and kills the whole file - which
# looks, from outside, exactly like a suite that noticed nothing.
function Check {
  param([string]$Name, [scriptblock]$Body, $Want)
  try {
    $got = & $Body
  } catch {
    Write-Host "FAIL ${Name}: threw instead of returning '$Want' - $_" -ForegroundColor Red
    $script:failed++
    return
  }
  if ("$got" -eq "$Want") { Write-Host "PASS $Name" -ForegroundColor Green }
  else { Write-Host "FAIL ${Name}: got '$got', want '$Want'" -ForegroundColor Red; $script:failed++ }
}

function Check-Throws {
  param([string]$Name, [scriptblock]$Body, [string]$Matching)
  try {
    $r = & $Body
    Write-Host "FAIL ${Name}: returned '$r' instead of throwing" -ForegroundColor Red
    $script:failed++
  } catch {
    if ("$_" -match $Matching) { Write-Host "PASS $Name" -ForegroundColor Green }
    else {
      Write-Host "FAIL ${Name}: threw, but the message does not match /$Matching/ - '$_'" -ForegroundColor Red
      $script:failed++
    }
  }
}

# ── an empty slot ──────────────────────────────────────────────────────
# The common case, and the one the real product was in when this was
# written: nothing pending, last published 0.12.9.0.
Check "no pending submission is a free slot" { & $script -PendingId '' } 'proceed'
# A status without an id cannot happen from `apps get`, but a status *is*
# what `submission get` returns for the last published submission - so if
# the caller ever wires the wrong field in, this is the case that must not
# be read as an occupied slot.
Check "a Published status with no pending id is still free" { & $script -PendingId '' -Status 'Published' } 'proceed'
# The pending id is the authority, not the status - and this is the case that
# says so. A status can arrive from the last published submission (that is
# what `submission get` hands back when nothing is pending), so a decision
# that keys on the status instead would refuse to publish over a slot that
# is standing empty. Without this case that swap changes no answer at all.
Check "an in-flight status with no pending id is still free" { & $script -PendingId '' -Status 'Certification' } 'proceed'

# ── a draft we own ─────────────────────────────────────────────────────
# `msstore publish --noCommit` overwrites these, so they are not obstacles.
Check "an uncommitted draft is ours to overwrite" { & $script -PendingId '123' -Status 'PendingCommit' } 'proceed'
Check "and so is one with no status yet" { & $script -PendingId '123' -Status '' } 'proceed'

# ── wedged ─────────────────────────────────────────────────────────────
# Neither updatable nor re-committable; delete and recreate is the API's own
# remedy. This used to be handled only for a product's FIRST submission,
# which is not where it happens.
Check "a CommitFailed draft is deleted" { & $script -PendingId '123' -Status 'CommitFailed' } 'delete'
Check "and a CertificationFailed one" { & $script -PendingId '123' -Status 'CertificationFailed' } 'delete'
# Without -Supersede, because a wedged draft is not a release anyone is
# waiting on - clearing it needs no permission.
Check "wedged does not need superseding turned on" { & $script -PendingId '123' -Status 'CommitFailed' } 'delete'

# ── in flight ──────────────────────────────────────────────────────────
foreach ($s in 'CommitStarted', 'PreProcessing', 'Certification', 'Release', 'Publishing', 'PendingPublication') {
  Check-Throws "$s stops the publish by default" { & $script -PendingId '123' -Status $s -HeldVersion '0.12.9.0' } 'one submission slot'
  Check "$s is superseded when asked" { & $script -PendingId '123' -Status $s -Supersede } 'delete'
}

# The whole point of the message: it has to name what is holding the slot,
# or the reader is back to guessing which version to wait for.
Check-Throws "the refusal names the version holding the slot" {
  & $script -PendingId '123' -Status 'Certification' -HeldVersion '0.12.9.0'
} '0\.12\.9\.0'
Check-Throws "and says how to get past it" {
  & $script -PendingId '123' -Status 'Certification' -HeldVersion '0.12.9.0'
} 'supersede-pending'
# With no version to name it must still say something identifiable.
Check-Throws "with no version it names the submission" {
  & $script -PendingId '1152921505701751180' -Status 'Certification'
} '1152921505701751180'

# ── the case that started all this ─────────────────────────────────────
# Published is NOT a pending status. It is what `submission get` returns
# when there is nothing pending, and reading it as an occupied slot would
# block every release forever.
Check "Published with an id present is not in flight" { & $script -PendingId '123' -Status 'Published' } 'proceed'

if ($failed) {
  Write-Host "$failed slot test(s) failed" -ForegroundColor Red
  exit 1
}
Write-Host "all slot tests passed" -ForegroundColor Green
