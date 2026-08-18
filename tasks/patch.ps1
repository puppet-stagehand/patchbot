# patchbot::patch (Windows implementation) — apply Windows Updates (all,
# security-only, or a specific set of patch_ids) and optionally reboot.
# Posture is reported back through the patchbot fact (facts.d/patchbot.ps1),
# not this task's output, so the Windows Update screen updates on the node's
# next Puppet run — same contract as the POSIX implementation in patch.sh.
#
# Uses the built-in Windows Update Agent (WUA) COM API directly — no
# PSWindowsUpdate module dependency, matching the rest of this module.
$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Error "ERROR: $msg"
  exit 1
}

$SecurityOnly = ($env:PT_security_only -eq 'true')
$DoReboot     = ($env:PT_reboot -eq 'true')
$PatchIdsRaw  = $env:PT_patch_ids

$PatchIds = @()
if ($PatchIdsRaw -and $PatchIdsRaw -ne 'null' -and $PatchIdsRaw -ne '[]') {
  try {
    $PatchIds = @($PatchIdsRaw | ConvertFrom-Json)
  } catch {
    Fail 'patch_ids must be a JSON array of strings'
  }
  if ($PatchIds.Count -eq 0) { Fail 'patch_ids was provided but parsed to an empty list' }
}

function Test-IsSecurityUpdate($update) {
  if ($update.MsrcSeverity) { return $true }
  foreach ($cat in $update.Categories) {
    if ($cat.Name -eq 'Security Updates') { return $true }
  }
  return $false
}

function Get-UpdateId($update) {
  if ($update.KBArticleIDs -and $update.KBArticleIDs.Count -gt 0) {
    return 'KB' + $update.KBArticleIDs[0]
  }
  return $update.Identity.UpdateID
}

try {
  $session  = New-Object -ComObject Microsoft.Update.Session
  $searcher = $session.CreateUpdateSearcher()
  $searchResult = $searcher.Search('IsInstalled=0 and IsHidden=0')

  $candidates = New-Object -ComObject Microsoft.Update.UpdateColl

  foreach ($update in $searchResult.Updates) {
    $include = $true
    if ($PatchIds.Count -gt 0) {
      $include = $PatchIds -contains (Get-UpdateId $update)
    } elseif ($SecurityOnly) {
      $include = Test-IsSecurityUpdate $update
    }
    if ($include) {
      if (-not $update.EulaAccepted) { $update.AcceptEula() | Out-Null }
      $candidates.Add($update) | Out-Null
    }
  }
} catch {
  Fail "update search failed: $($_.Exception.Message)"
}

$applied = if ($PatchIds.Count -gt 0) { 'selected' } elseif ($SecurityOnly) { 'security' } else { 'all' }
$rebootRequired = $false

if ($candidates.Count -gt 0) {
  try {
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $candidates
    $downloader.Download() | Out-Null

    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $candidates
    $installResult = $installer.Install()
    $rebootRequired = [bool]$installResult.RebootRequired
  } catch {
    Fail "update install failed: $($_.Exception.Message)"
  }
} else {
  # Nothing matched (e.g. patch_ids named updates that are no longer
  # offered) — still report any pre-existing pending reboot honestly.
  $rebootRequired = [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired
}

# Refresh the patchbot external fact cache best-effort so PuppetDB/console
# see the new posture promptly (the fact also self-reports on the next
# agent run) — mirrors patch.sh's own best-effort self-refresh.
$factPath = Join-Path $env:ProgramData 'PuppetLabs\facter\facts.d\patchbot.ps1'
if (Test-Path $factPath) {
  try { & $factPath | Out-Null } catch { }
}

if ($DoReboot -and $rebootRequired) {
  $result = [pscustomobject]@{
    status          = 'patched'
    applied         = $applied
    reboot_required = $rebootRequired
    rebooting       = $true
  }
  $result | ConvertTo-Json -Compress
  # Give Bolt time to collect output before the connection drops.
  Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r', '/t', '5', '/c', 'patchbot reboot' | Out-Null
  exit 0
}

$result = [pscustomobject]@{
  status          = 'patched'
  applied         = $applied
  reboot_required = $rebootRequired
  rebooted        = $false
}
$result | ConvertTo-Json -Compress
