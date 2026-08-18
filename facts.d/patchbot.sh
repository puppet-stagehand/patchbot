#!/bin/sh
# pcm_patch — external fact (facts.d, pluginsynced from the pcm module).
# Patch posture the console reads (Patching page + Action Center):
#   {"pcm_patch": {"available": N, "security": N, "reboot_required": bool,
#                  "last_checked": "<ISO8601 UTC>"}}
# Structured JSON output requires Facter 4 (Puppet 8 — i.e. Puppet Core;
# the only stack we target, see docs: NO OpenVox).
#
# Renamed from the legacy `patches` fact at the pcm cutover (2026-07-21).
# Deploy: pcm/facts.d via pluginsync once pcm is in the environment
# modulepath, or drop into /etc/puppetlabs/facter/facts.d/ (chmod 755).
set -u

AVAILABLE=0
SECURITY=0
REBOOT=false

if command -v apt-get >/dev/null 2>&1; then
  # Simulated dist-upgrade: count Inst lines; security = those from a
  # -security suite. Uses the package cache only (no network) — the pcm
  # patch task and unattended-upgrades keep the cache fresh.
  UPGR=$(apt-get -s dist-upgrade 2>/dev/null | grep '^Inst ' || true)
  [ -n "$UPGR" ] && AVAILABLE=$(printf '%s\n' "$UPGR" | wc -l | tr -d ' ')
  [ -n "$UPGR" ] && SECURITY=$(printf '%s\n' "$UPGR" | grep -ci 'security' || true)
  [ -f /var/run/reboot-required ] && REBOOT=true
elif command -v dnf >/dev/null 2>&1; then
  # `check-update -q` exits 100 with a package list when updates exist.
  LIST=$(dnf -q check-update 2>/dev/null | awk 'NF>=3 && $1 !~ /^Obsoleting/ {print $1}' || true)
  [ -n "$LIST" ] && AVAILABLE=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
  SECURITY=$(dnf -q updateinfo list security --available 2>/dev/null | grep -c '/' || true)
  # needs-restarting -r: exit 0 = no reboot, exit 1 = reboot required.
  # Only trust an explicit 1 — a missing plugin exits differently.
  dnf -q needs-restarting -r >/dev/null 2>&1
  [ $? -eq 1 ] && REBOOT=true
elif command -v yum >/dev/null 2>&1; then
  LIST=$(yum -q check-update 2>/dev/null | awk 'NF>=3 {print $1}' || true)
  [ -n "$LIST" ] && AVAILABLE=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
  SECURITY=$(yum -q updateinfo list security 2>/dev/null | grep -c '/' || true)
  needs-restarting -r >/dev/null 2>&1
  [ $? -eq 1 ] && REBOOT=true
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"pcm_patch": {"available": %s, "security": %s, "reboot_required": %s, "last_checked": "%s"}}\n' \
  "${AVAILABLE:-0}" "${SECURITY:-0}" "$REBOOT" "$NOW"
