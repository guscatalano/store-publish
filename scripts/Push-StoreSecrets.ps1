#requires -Version 7
<#
.SYNOPSIS
  Push the four Partner Center API secrets to every Store-app repo in one go.

.DESCRIPTION
  Personal GitHub accounts can't share secrets across repos, so each repo needs its own copy
  of the same four values. This prompts once (input hidden) and pushes them everywhere via
  `gh secret set`. The values are the SAME ones already working in guscatalano/findneedle
  (Entra app registration with Partner Center API access) - grab them from wherever you
  stored them when setting up findneedle, or from portal.azure.com > App registrations.

.EXAMPLE
  ./Push-StoreSecrets.ps1                     # all known Store app repos
  ./Push-StoreSecrets.ps1 -Repos guscatalano/BinaryExplorer
#>
[CmdletBinding()]
param(
  [string[]] $Repos = @(
    'guscatalano/BinaryExplorer',
    'guscatalano/DriveVisualizer',
    'guscatalano/SimpleEventViewer',
    'guscatalano/AI_Proxy',
    'guscatalano/PixelPet',
    'guscatalano/SimplePCapViewer'
  )
)

$ErrorActionPreference = 'Stop'

$names = 'STORE_TENANT_ID', 'STORE_CLIENT_ID', 'STORE_CLIENT_SECRET', 'STORE_SELLER_ID'
$values = @{}
foreach ($n in $names) {
  $secure = Read-Host -Prompt $n -AsSecureString
  $values[$n] = [System.Net.NetworkCredential]::new('', $secure).Password
  if (-not $values[$n]) { throw "$n is empty." }
}

foreach ($repo in $Repos) {
  Write-Host "== $repo" -ForegroundColor Cyan
  foreach ($n in $names) {
    $values[$n] | gh secret set $n --repo $repo
    if ($LASTEXITCODE -ne 0) { throw "gh secret set $n failed for $repo" }
    Write-Host "  set $n"
  }
}
Write-Host "Done - $($Repos.Count) repo(s) configured." -ForegroundColor Green
