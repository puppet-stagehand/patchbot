#!/bin/sh
# patchbot — external fact (facts.d, pluginsynced from the patchbot module).
# Patch posture the console reads (Patching page + Action Center):
#   {"patchbot": {"available": N, "security": N, "reboot_required": bool,
#                 "last_checked": "<ISO8601 UTC>",
#                 "patches": [{"id","severity","security"}, ...]}}
# Structured JSON output requires Facter 4 (ships with Puppet 8 — OpenVox,
# Puppet Core, and PE all qualify).
#
# `patches[]` backs the console's per-patch picker (Windows Update screen
# today; nothing here is Windows-specific). Deliberately id+severity+security
# only — no title — to keep the fact small; PuppetDB stores this and it's
# re-sent every agent run. The console resolves human-readable titles itself.
# See docs/design/patchbot-fact-schema-spec.md (filed in the project's AI
# vault, not this repo) for the full rationale.
#
# Severity here is an approximation, not a per-CVE rating: Linux package
# managers don't cleanly expose per-package severity the way Windows' WUA
# does (see facts.d/patchbot.ps1) without heavier tooling (debsecan, dnf5's
# richer API) this module deliberately doesn't pull in. A package is
# `security: true, severity: "high"` if the package manager's own
# security-update channel flags it; everything else is
# `security: false, severity: "unknown"`.
#
# Split out of the stagehand module into its own patchbot module (2026-08-18);
# originally renamed from the legacy `patches` fact at the pcm/stagehand cutover
# (2026-07-21).
# Deploy: patchbot/facts.d via pluginsync once patchbot is in the environment
# modulepath, or drop into /etc/puppetlabs/facter/facts.d/ (chmod 755).
set -u

AVAILABLE=0
SECURITY=0
REBOOT=false
PATCHES=""

# Appends one {"id":...,"severity":...,"security":...} object to $PATCHES.
# Package/KB identifiers are controlled strings from the package manager
# itself (never free-form user text), so no JSON-string escaping is needed.
add_patch() {
  _id="$1" _sev="$2" _sec="$3"
  _entry="{\"id\": \"${_id}\", \"severity\": \"${_sev}\", \"security\": ${_sec}}"
  if [ -z "$PATCHES" ]; then
    PATCHES="$_entry"
  else
    PATCHES="${PATCHES}, ${_entry}"
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  # Simulated dist-upgrade: count Inst lines; security = those from a
  # -security suite. Uses the package cache only (no network) — the patchbot
  # patch task and unattended-upgrades keep the cache fresh.
  UPGR=$(apt-get -s dist-upgrade 2>/dev/null | grep '^Inst ' || true)
  if [ -n "$UPGR" ]; then
    AVAILABLE=$(printf '%s\n' "$UPGR" | wc -l | tr -d ' ')
    SECURITY=$(printf '%s\n' "$UPGR" | grep -ci 'security' || true)
    OLDIFS=$IFS
    IFS='
'
    for LINE in $UPGR; do
      PKG=$(printf '%s\n' "$LINE" | awk '{print $2}')
      [ -n "$PKG" ] || continue
      if printf '%s\n' "$LINE" | grep -qi 'security'; then
        add_patch "$PKG" "high" "true"
      else
        add_patch "$PKG" "unknown" "false"
      fi
    done
    IFS=$OLDIFS
  fi
  [ -f /var/run/reboot-required ] && REBOOT=true

elif command -v dnf >/dev/null 2>&1; then
  # `check-update -q` exits 100 with a package list when updates exist.
  LIST=$(dnf -q check-update 2>/dev/null | awk 'NF>=3 && $1 !~ /^Obsoleting/ {print $1}' || true)
  # Advisory severity for the security subset (e.g. "Important/Sec." NEVRA);
  # cross-referenced below by NEVRA-prefix match against each $LIST entry's
  # bare package name — RPM NEVRA always starts "<name>-<version>...", so a
  # "name-" prefix match is a reliable (if not bulletproof) correlation.
  SECLIST=$(dnf -q updateinfo list security --available 2>/dev/null | awk 'NF>=3 {print $2, $3}' || true)
  SECURITY=$(printf '%s\n' "$SECLIST" | grep -c '.' || true)
  if [ -n "$LIST" ]; then
    AVAILABLE=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
    OLDIFS=$IFS
    IFS='
'
    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      NAME=${ENTRY%.*}
      MATCH=$(printf '%s\n' "$SECLIST" | grep -m1 -- "${NAME}-" || true)
      if [ -n "$MATCH" ]; then
        SEV=$(printf '%s\n' "$MATCH" | awk '{print $1}' | sed -E 's#/Sec\.?$##' | tr '[:upper:]' '[:lower:]')
        case "$SEV" in
          critical|important) add_patch "$ENTRY" "high" "true" ;;
          moderate)            add_patch "$ENTRY" "medium" "true" ;;
          low)                 add_patch "$ENTRY" "low" "true" ;;
          *)                   add_patch "$ENTRY" "high" "true" ;;
        esac
      else
        add_patch "$ENTRY" "unknown" "false"
      fi
    done
    IFS=$OLDIFS
  fi
  # needs-restarting -r: exit 0 = no reboot, exit 1 = reboot required.
  # Only trust an explicit 1 — a missing plugin exits differently.
  dnf -q needs-restarting -r >/dev/null 2>&1
  [ $? -eq 1 ] && REBOOT=true

elif command -v yum >/dev/null 2>&1; then
  LIST=$(yum -q check-update 2>/dev/null | awk 'NF>=3 {print $1}' || true)
  SECLIST=$(yum -q updateinfo list security 2>/dev/null | awk 'NF>=3 {print $2, $3}' || true)
  SECURITY=$(printf '%s\n' "$SECLIST" | grep -c '.' || true)
  if [ -n "$LIST" ]; then
    AVAILABLE=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
    OLDIFS=$IFS
    IFS='
'
    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      NAME=${ENTRY%.*}
      MATCH=$(printf '%s\n' "$SECLIST" | grep -m1 -- "${NAME}-" || true)
      if [ -n "$MATCH" ]; then
        SEV=$(printf '%s\n' "$MATCH" | awk '{print $1}' | sed -E 's#/Sec\.?$##' | tr '[:upper:]' '[:lower:]')
        case "$SEV" in
          critical|important) add_patch "$ENTRY" "high" "true" ;;
          moderate)            add_patch "$ENTRY" "medium" "true" ;;
          low)                 add_patch "$ENTRY" "low" "true" ;;
          *)                   add_patch "$ENTRY" "high" "true" ;;
        esac
      else
        add_patch "$ENTRY" "unknown" "false"
      fi
    done
    IFS=$OLDIFS
  fi
  needs-restarting -r >/dev/null 2>&1
  [ $? -eq 1 ] && REBOOT=true
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"patchbot": {"available": %s, "security": %s, "reboot_required": %s, "last_checked": "%s", "patches": [%s]}}\n' \
  "${AVAILABLE:-0}" "${SECURITY:-0}" "$REBOOT" "$NOW" "$PATCHES"
