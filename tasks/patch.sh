#!/bin/sh
# patchbot::patch — apply OS package updates (all, security-only, or a
# specific set of patch_ids) and optionally reboot. Posture is reported back
# through the patchbot fact, not this task's output, so the Patching page
# updates on the node's next Puppet run.
set -u

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SECURITY_ONLY="${PT_security_only:-false}"
DO_REBOOT="${PT_reboot:-false}"
PATCH_IDS_RAW="${PT_patch_ids:-}"

# patch_ids (JSON array of ids from the patchbot fact's patches[]) takes
# priority over security_only when both are set — installing an explicit
# list is inherently more specific than "security-only". Bolt's
# input_method=environment JSON-encodes array params into the env var, so
# jq is only required when this parameter is actually used — every other
# path in this task stays dependency-light.
PATCH_IDS=""
if [ -n "$PATCH_IDS_RAW" ] && [ "$PATCH_IDS_RAW" != "null" ] && [ "$PATCH_IDS_RAW" != "[]" ]; then
  command -v jq >/dev/null 2>&1 || die "jq is required on the target to use patch_ids"
  PATCH_IDS=$(printf '%s' "$PATCH_IDS_RAW" | jq -r '.[]' 2>/dev/null) || die "patch_ids must be a JSON array of strings"
  [ -n "$PATCH_IDS" ] || die "patch_ids was provided but parsed to an empty list"
fi

APPLIED="unknown"
REBOOTED="false"
REBOOT_REQUIRED="false"

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
  apt-get -qq update >/dev/null 2>&1 || die "apt-get update failed"
  if [ -n "$PATCH_IDS" ]; then
    # shellcheck disable=SC2086
    apt-get -y install $PATCH_IDS >/dev/null 2>&1 || die "apt install of selected patch_ids failed"
    APPLIED="selected"
  elif [ "$SECURITY_ONLY" = "true" ]; then
    if command -v unattended-upgrade >/dev/null 2>&1; then
      unattended-upgrade >/dev/null 2>&1 || die "unattended-upgrade failed"
      APPLIED="security"
    else
      # Approximate security-only: upgrade packages from a *-security suite.
      PKGS=$(apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst / && /security/i {print $2}')
      if [ -n "$PKGS" ]; then
        # shellcheck disable=SC2086
        apt-get -y install $PKGS >/dev/null 2>&1 || die "apt security upgrade failed"
      fi
      APPLIED="security"
    fi
  else
    apt-get -y dist-upgrade >/dev/null 2>&1 || die "apt dist-upgrade failed"
    APPLIED="all"
  fi
  [ -f /var/run/reboot-required ] && REBOOT_REQUIRED="true"

elif command -v dnf >/dev/null 2>&1; then
  if [ -n "$PATCH_IDS" ]; then
    # shellcheck disable=SC2086
    dnf -y upgrade $PATCH_IDS >/dev/null 2>&1 || die "dnf upgrade of selected patch_ids failed"
    APPLIED="selected"
  elif [ "$SECURITY_ONLY" = "true" ]; then
    dnf -y --security upgrade >/dev/null 2>&1 || die "dnf security upgrade failed"
    APPLIED="security"
  else
    dnf -y upgrade >/dev/null 2>&1 || die "dnf upgrade failed"
    APPLIED="all"
  fi
  if command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1 || REBOOT_REQUIRED="true"
  fi

elif command -v yum >/dev/null 2>&1; then
  if [ -n "$PATCH_IDS" ]; then
    # shellcheck disable=SC2086
    yum -y update $PATCH_IDS >/dev/null 2>&1 || die "yum update of selected patch_ids failed"
    APPLIED="selected"
  elif [ "$SECURITY_ONLY" = "true" ]; then
    yum -y --security update >/dev/null 2>&1 || die "yum security update failed"
    APPLIED="security"
  else
    yum -y update >/dev/null 2>&1 || die "yum update failed"
    APPLIED="all"
  fi
  if command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1 || REBOOT_REQUIRED="true"
  fi
else
  die "no supported package manager (apt/dnf/yum) found"
fi

# Refresh the patchbot external fact cache best-effort so PuppetDB/console see
# the new posture promptly (the fact also self-reports on the next agent run).
if [ -x /etc/puppetlabs/facter/facts.d/patchbot.sh ]; then
  /etc/puppetlabs/facter/facts.d/patchbot.sh >/dev/null 2>&1 || true
fi

if [ "$DO_REBOOT" = "true" ] && [ "$REBOOT_REQUIRED" = "true" ]; then
  REBOOTED="true"
  printf '{"status": "patched", "applied": "%s", "reboot_required": %s, "rebooting": true}\n' \
    "$APPLIED" "$REBOOT_REQUIRED"
  # Give Bolt time to collect output before the link drops.
  (sleep 3; systemctl reboot 2>/dev/null || shutdown -r now 2>/dev/null || reboot) >/dev/null 2>&1 &
  exit 0
fi

printf '{"status": "patched", "applied": "%s", "reboot_required": %s, "rebooted": %s}\n' \
  "$APPLIED" "$REBOOT_REQUIRED" "$REBOOTED"
