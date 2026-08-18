# patchbot.ps1 — external fact (facts.d, pluginsynced from the patchbot
# module). Windows counterpart to facts.d/patchbot.sh — identical JSON shape:
#   {"patchbot": {"available": N, "security": N, "reboot_required": bool,
#                 "last_checked": "<ISO8601 UTC>",
#                 "patches": [{"id","severity","security"}, ...]}}
#
# Facter's facts.d loader runs .ps1 scripts directly on Windows (no wrapping
# .bat needed) and, on Linux, simply skips this file (not executable, no
# shebang) — patchbot.sh and patchbot.ps1 coexist in the same facts.d/ and
# only the platform-appropriate one ever actually runs.
#
# Uses the built-in Windows Update Agent (WUA) COM API directly — no
# PSWindowsUpdate module dependency, matching this module's dependency-light
# design (same reasoning as the shell fact needing no jq/python).
#
# Severity: MSRC's four-tier rating (Critical/Important/Moderate/Low) maps
# onto the shared low/medium/high/unknown enum used across the whole
# product (compliance.v1's severity field, and the Linux side of this same
# fact). Critical and Important both collapse to "high" — matching
# trivy-report.sh's own CRITICAL/HIGH -> high collapse — so a Windows node
# and a Linux node report severity on the same three-plus-unknown scale.
# Updates with no MsrcSeverity (most non-security updates) are "unknown".

$ErrorActionPreference = 'Stop'

function ConvertTo-Severity {
  param($Msrc)
  switch (([string]$Msrc).Trim().ToLowerInvariant()) {
    'critical'  { 'high' }
    'important' { 'high' }
    'moderate'  { 'medium' }
    'low'       { 'low' }
    default     { 'unknown' }
  }
}

function New-EmptyFact {
  [pscustomobject]@{
    patchbot = [pscustomobject]@{
      available       = 0
      security        = 0
      reboot_required = $false
      last_checked    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      patches         = @()
    }
  }
}

try {
  $session  = New-Object -ComObject Microsoft.Update.Session
  $searcher = $session.CreateUpdateSearcher()
  # IsHidden=0: match what a user checking Windows Update manually would
  # see — dismissed/postponed updates are excluded, same as the console's
  # "double-click Windows Update" framing.
  $result = $searcher.Search('IsInstalled=0 and IsHidden=0')

  $patches = @()
  $securityCount = 0

  foreach ($update in $result.Updates) {
    $isSecurity = $false
    if ($update.MsrcSeverity) {
      $isSecurity = $true
    } else {
      foreach ($cat in $update.Categories) {
        if ($cat.Name -eq 'Security Updates') { $isSecurity = $true; break }
      }
    }
    if ($isSecurity) { $securityCount++ }

    if ($update.KBArticleIDs -and $update.KBArticleIDs.Count -gt 0) {
      $id = 'KB' + $update.KBArticleIDs[0]
    } else {
      # Rare: an update with no KB (e.g. a driver update) falls back to its
      # WUA-internal UpdateID GUID so it still has a stable, unique `id`.
      $id = $update.Identity.UpdateID
    }

    $patches += [pscustomobject]@{
      id       = $id
      severity = if ($isSecurity) { ConvertTo-Severity $update.MsrcSeverity } else { 'unknown' }
      security = $isSecurity
    }
  }

  $rebootRequired = [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired

  $fact = [pscustomobject]@{
    patchbot = [pscustomobject]@{
      available       = $result.Updates.Count
      security        = $securityCount
      reboot_required = $rebootRequired
      last_checked    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      patches         = @($patches)
    }
  }
} catch {
  # Same contract as the shell fact: never break a Puppet run over a
  # patch-posture read failure — report a zeroed, honest "couldn't check"
  # state instead of crashing pluginsync'd fact resolution.
  $fact = New-EmptyFact
}

$fact | ConvertTo-Json -Depth 6 -Compress
