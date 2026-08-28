<#
.SYNOPSIS
  What to do about whatever is already in the Store's one submission slot.

.DESCRIPTION
  A product has exactly ONE submission slot. Whatever is sitting in it decides
  whether the tag being published can be submitted at all, and the failure when
  it cannot is opaque: `msstore publish --noCommit` against an occupied slot
  reports nothing that names the version holding it.

  This is that decision, on its own so it can be tested. It returns:

    proceed  - the slot is free, or holds an uncommitted draft that
               `msstore publish --noCommit` will overwrite.
    delete   - the caller must `msstore submission delete` first: either the
               draft is wedged, or it is in flight and the caller asked for
               the newest tag to win.

  and throws, with a message naming the version and the status, when the slot
  is held by something in flight and superseding was not asked for.

  Note on how the caller learns PendingId: from `msstore apps get`, the app's
  PendingApplicationSubmission.Id - NEVER from the exit code of `msstore
  submission get`. With nothing pending that command falls back to the last
  PUBLISHED submission and still exits 0, so its exit code cannot tell a
  finished release from a draft in progress.
#>
[CmdletBinding()]
param(
  # Empty when the app has no pending submission at all.
  [AllowEmptyString()] [string]$PendingId = '',
  # Status of that pending submission, as reported by `msstore submission get`.
  [AllowEmptyString()] [string]$Status = '',
  # Version it carries, for the error message.
  [AllowEmptyString()] [string]$HeldVersion = '',
  # What we are trying to submit, for the error message.
  [AllowEmptyString()] [string]$PackageName = '',
  # Newest tag wins: delete an in-flight submission so this one takes the slot.
  [switch]$Supersede
)

$ErrorActionPreference = 'Stop'

# Wedged. Neither updatable nor re-committable - the API answers 409
# InvalidState to both, and its own remedy is delete and recreate.
$wedged = @('CommitFailed', 'CertificationFailed')

# In flight. The Store will not take anything else until it clears, whether
# that is minutes (preprocessing) or days (certification).
$inFlight = @(
  'CommitStarted',
  'PreProcessing',
  'Certification',
  'Release',
  'Publishing',
  'PendingPublication'
)

if (-not $PendingId) { return 'proceed' }

$held = if ($HeldVersion) { "version $HeldVersion" } else { "submission $PendingId" }

if ($Status -in $wedged) { return 'delete' }

if ($Status -in $inFlight) {
  if ($Supersede) { return 'delete' }
  throw "$held is already in the Store's one submission slot ($Status), so nothing was submitted. Wait for it to finish, cancel it in Partner Center, or set supersede-pending: true on this workflow to let a newer tag take the slot."
}

# Anything else is an uncommitted draft, which is ours to overwrite. Includes
# the empty status, which is what a slot created but never filled looks like.
return 'proceed'
