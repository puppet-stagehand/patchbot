#!/bin/sh
# patchbot — external fact (facts.d, pluginsynced from the patchbot module).
# Patch posture the console reads (Patching page + Action Center):
#   {"patchbot": {"available": N, "security": N, "reboot_required": bool,
#                 "last_checked": "<ISO8601 UTC>",
#                 "packages": [{"name","arch","current","available","repo","security"}, ...]}}
#   (apt, dnf and yum all emit this shape as of 999.47-03. See 999.47-01 for
#   apt, 999.47-03 for dnf/yum -- the three branches converged onto one
#   shape via shared add_package/json_escape/rpm_installed_versions helpers
#   rather than each formatting its own JSON.)
# Structured JSON output requires Facter 4 (ships with Puppet 8 — OpenVox,
# Puppet Core, and PE all qualify).
#
# `packages[]` backs the console's per-patch picker (Windows Update screen
# today; nothing here is Windows-specific) and the Patching > Packages tab's
# version/source columns. Entries carry name, arch, current (installed)
# version, available version, repo/suite and a security boolean -- adopted
# from adapters/stagehand/facts.d/patchbot.sh's already-documented shape
# (D-02, 2026-09-23 design: docs/superpowers/specs/2026-09-23-patching-package-version-source-design.md)
# rather than inventing a third shape on top of the legacy "deliberately
# id+severity+security only" `patches[]` array. dnf/yum's `current` (the
# installed version) comes from a second, batched `rpm -q` lookup
# (rpm_installed_versions) since `check-update` only reports the candidate
# version -- one process invocation per fact run, not one per pending
# package (T-999.47-11).
#
# `patches[]` is no longer emitted by any branch of this script. The
# console's read side (patchFactPackages, backend/internal/httpapi/patching.go)
# still tries "packages" first and falls back to "patches" -- that fallback
# is the degradation path for any node still running a pre-999.47 copy of
# this module during rollout (spec section 7), not dead code to delete.
#
# Severity is no longer tracked as a separate field for the packages[] shape
# -- only the "security" boolean survives (D-02). Linux package managers
# don't cleanly expose per-package severity the way Windows' WUA does (see
# facts.d/patchbot.ps1) without heavier tooling (debsecan, dnf5's richer
# API) this module deliberately doesn't pull in. A package is
# `security: true` if the package manager's own security-update channel (or
# advisory list) flags it; everything else is `security: false`.
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
PACKAGES=""

# json_escape backslash-and-quote-escapes a value before it is interpolated
# into emitted JSON (T-999.47-01: suite/version/arch strings, unlike the bare
# package names the legacy add_patch call trusted, are less tightly
# controlled). Mirrors adapters/stagehand/facts.d/patchbot.sh's esc()
# (backslash substitution before quote substitution, same order).
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Appends one {"name","arch","current","available","repo","security"} object
# to $PACKAGES. Used by all three branches (apt: 999.47-01; dnf/yum:
# 999.47-03). Every string field is routed through json_escape first.
add_package() {
  _name=$(json_escape "$1")
  _arch=$(json_escape "$2")
  _cur=$(json_escape "$3")
  _avail=$(json_escape "$4")
  _repo=$(json_escape "$5")
  _sec="$6"
  _entry="{\"name\": \"${_name}\", \"arch\": \"${_arch}\", \"current\": \"${_cur}\", \"available\": \"${_avail}\", \"repo\": \"${_repo}\", \"security\": ${_sec}}"
  if [ -z "$PACKAGES" ]; then
    PACKAGES="$_entry"
  else
    PACKAGES="${PACKAGES}, ${_entry}"
  fi
}

# pkgname_is_safe validates that NAME is a plain package-name token before it
# reaches rpm's argv (T-999.47-09, same argument-injection class the
# patchbot patch task's own patch_ids validation already fixed --
# tasks/patch.sh's `[A-Za-z0-9][A-Za-z0-9._:+-]*` shape). A name containing
# whitespace or a leading dash would otherwise split into extra argv entries
# or be read as an rpm flag. A name that fails this check is simply skipped
# -- it never reaches rpm_installed_versions, so it contributes no "current"
# value, which the collapse rule already treats as an empty-tuple
# contributor rather than a fatal error.
pkgname_is_safe() {
  case "$1" in
    '') return 1 ;;
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._:+-]*) return 1 ;;
  esac
  return 0
}

# rpm_installed_versions NAMES...
#
# Runs exactly ONE `rpm -q` invocation across every pending package name,
# emitting one "name version" line per name rpm recognizes on stdout. This
# is the mitigation for the open risk spec section 9 records (T-999.47-11):
# the naive shape is one `rpm -q` per pending package, which on a node with
# hundreds of pending updates is the place fact-collection time noticeably
# grows -- batching it into one invocation makes the cost constant instead
# of linear in the number of pending packages. Names are passed after `--`
# (T-999.47-09) and stderr is discarded so an unrecognized name does not
# abort the run.
rpm_installed_versions() {
  [ "$#" -gt 0 ] || return 0
  rpm -q --queryformat '%{NAME} %|EPOCH?{%{EPOCH}:}:{}|%{VERSION}-%{RELEASE}\n' -- "$@" 2>/dev/null
  return 0
}

# rpm_installed_version_for NAME TABLE
#
# Resolves NAME against the "name version" TABLE rpm_installed_versions
# produced, returning the first match on stdout. A multilib pair (i686 and
# x86_64 reported as two lines for the same name) would otherwise double the
# emitted entry count -- taking the first keeps exactly one entry per
# check-update line. Prints nothing (empty "current") when NAME is absent
# from TABLE.
rpm_installed_version_for() {
  printf '%s\n' "$2" | awk -v name="$1" '$1 == name { print $2; exit }'
}

if command -v apt-get >/dev/null 2>&1; then
  # Simulated dist-upgrade: count Inst lines; security = those from a
  # -security suite. Uses the package cache only (no network) — the patchbot
  # patch task and unattended-upgrades keep the cache fresh.
  #
  #   Inst openssl [3.0.2-0ubuntu1.15] (3.0.2-0ubuntu1.18 Ubuntu:24.04/noble-security [amd64])
  #
  # A package pulled in fresh as a dependency has no [current] bracket, so
  # the third field is parsed defensively rather than positionally (ported
  # from adapters/stagehand/facts.d/patchbot.sh's apt awk block, the proven
  # reference implementation of this exact parse).
  UPGR=$(apt-get -s dist-upgrade 2>/dev/null | grep '^Inst ' || true)
  if [ -n "$UPGR" ]; then
    AVAILABLE=$(printf '%s\n' "$UPGR" | wc -l | tr -d ' ')
    SECURITY=$(printf '%s\n' "$UPGR" | grep -ci 'security' || true)
    OLDIFS=$IFS
    IFS='
'
    # Field separator between the five extracted values below: the ASCII
    # Unit Separator (0x1F), not a tab -- POSIX `read` treats IFS tab as
    # whitespace and collapses adjacent delimiters (silently dropping an
    # empty "current" field, e.g. a freshly-pulled dependency with no
    # [current] bracket), which a non-whitespace IFS character does not.
    USEP=$(printf '\037')
    for LINE in $UPGR; do
      FIELDS=$(printf '%s\n' "$LINE" | awk -v usep="$USEP" '
        {
          name = $2
          cur = ""
          if ($3 ~ /^\[/) { cur = $3; gsub(/[][]/, "", cur) }

          p = index($0, "(")
          rest = (p ? substr($0, p + 1) : "")
          split(rest, r, " ")
          avail = r[1]

          # Origins look like "Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security".
          # Take the suite of the first one as the repo.
          repo = ""
          if (match(rest, /\/[A-Za-z0-9._-]+/)) {
            repo = substr(rest, RSTART + 1, RLENGTH - 1)
          }

          arch = ""
          if (match(rest, /\[[A-Za-z0-9_-]+\][)]?[ ]*$/)) {
            arch = substr(rest, RSTART + 1, RLENGTH - 1)
            gsub(/[])] */, "", arch)
          }

          printf "%s%s%s%s%s%s%s%s%s", name, usep, cur, usep, avail, usep, repo, usep, arch
        }')
      [ -n "$FIELDS" ] || continue
      IFS="$USEP" read -r PKG_NAME PKG_CUR PKG_AVAIL PKG_REPO PKG_ARCH <<PKGFIELDS
$FIELDS
PKGFIELDS
      [ -n "$PKG_NAME" ] || continue
      # Security determination stays byte-for-byte the legacy behavior: a
      # case-insensitive "security" match against the WHOLE Inst line, not
      # adapters/stagehand's stricter "-security"-suite-only match (that is a
      # different fleet-wide security count and out of scope here).
      if printf '%s\n' "$LINE" | grep -qi 'security'; then
        add_package "$PKG_NAME" "$PKG_ARCH" "$PKG_CUR" "$PKG_AVAIL" "$PKG_REPO" "true"
      else
        add_package "$PKG_NAME" "$PKG_ARCH" "$PKG_CUR" "$PKG_AVAIL" "$PKG_REPO" "false"
      fi
    done
    IFS=$OLDIFS
  fi
  [ -f /var/run/reboot-required ] && REBOOT=true

elif command -v dnf >/dev/null 2>&1; then
  # `check-update -q` exits 100 with a package list when updates exist:
  #   openssl.x86_64  1:3.2.2-6.el9_5  rhel-9-appstream
  # Column 2 is the CANDIDATE (available) version, not the installed one --
  # check-update never reports what's currently installed, so the batched
  # rpm_installed_versions lookup below is what makes `current` true
  # (D-02, spec S4). NF>=3 and the Obsoleting guard are unchanged from the
  # legacy parse -- both already drop the lines that must be dropped (the
  # NF>=3 filter also silently drops a wrapped two-line check-update entry,
  # a pre-existing limitation this plan does not change).
  LIST=$(dnf -q check-update 2>/dev/null | awk 'NF>=3 && $1 !~ /^Obsoleting/ {print}' || true)
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
    # Pass 1: collect every pending package's bare name (arch stripped via
    # the branch's existing name.arch trailing-component convention),
    # validated by pkgname_is_safe (T-999.47-09) before it can reach rpm's
    # argv. An invalid name is skipped, not aborted -- see pkgname_is_safe.
    NAMES=""
    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      NAMEARCH=$(printf '%s\n' "$ENTRY" | awk '{print $1}')
      NAME=${NAMEARCH%.*}
      if pkgname_is_safe "$NAME"; then
        NAMES="${NAMES}${NAMES:+ }${NAME}"
      fi
    done
    # shellcheck disable=SC2086 # intentional word-splitting: NAMES is a
    # space-joined list of already-validated (pkgname_is_safe) tokens, and
    # this is the ONE batched rpm -q call (T-999.47-11) rather than one per
    # package.
    RPM_TABLE=$(rpm_installed_versions $NAMES)

    # Pass 2: emit one packages[] entry per check-update line.
    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      NAMEARCH=$(printf '%s\n' "$ENTRY" | awk '{print $1}')
      AVAIL=$(printf '%s\n' "$ENTRY" | awk '{print $2}')
      REPO=$(printf '%s\n' "$ENTRY" | awk '{print $3}')
      NAME=${NAMEARCH%.*}
      ARCH=${NAMEARCH##*.}
      CUR=$(rpm_installed_version_for "$NAME" "$RPM_TABLE")
      MATCH=$(printf '%s\n' "$SECLIST" | grep -m1 -- "${NAME}-" || true)
      if [ -n "$MATCH" ]; then
        SEV=$(printf '%s\n' "$MATCH" | awk '{print $1}' | sed -E 's#/Sec\.?$##' | tr '[:upper:]' '[:lower:]')
        case "$SEV" in
          critical|important) add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true" ;;
          moderate)            add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true" ;;
          low)                 add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true" ;;
          *)                   add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true" ;;
        esac
      else
        add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "false"
      fi
    done
    IFS=$OLDIFS
  fi
  # needs-restarting -r: exit 0 = no reboot, exit 1 = reboot required.
  # Only trust an explicit 1 — a missing plugin exits differently.
  dnf -q needs-restarting -r >/dev/null 2>&1
  [ $? -eq 1 ] && REBOOT=true

elif command -v yum >/dev/null 2>&1; then
  # Same shape as the dnf branch above, reusing rpm_installed_versions,
  # rpm_installed_version_for, pkgname_is_safe, add_package and json_escape
  # rather than duplicating any of them. Every yum-specific difference from
  # the dnf branch stays intact: no Obsoleting guard, the bare
  # needs-restarting reboot probe (not `yum -q needs-restarting`), and its
  # own SECLIST invocation.
  LIST=$(yum -q check-update 2>/dev/null | awk 'NF>=3 {print}' || true)
  SECLIST=$(yum -q updateinfo list security 2>/dev/null | awk 'NF>=3 {print $2, $3}' || true)
  SECURITY=$(printf '%s\n' "$SECLIST" | grep -c '.' || true)
  if [ -n "$LIST" ]; then
    AVAILABLE=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
    OLDIFS=$IFS
    IFS='
'
    NAMES=""
    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      NAMEARCH=$(printf '%s\n' "$ENTRY" | awk '{print $1}')
      NAME=${NAMEARCH%.*}
      if pkgname_is_safe "$NAME"; then
        NAMES="${NAMES}${NAMES:+ }${NAME}"
      fi
    done
    # shellcheck disable=SC2086 # intentional word-splitting: NAMES is a
    # space-joined list of already-validated (pkgname_is_safe) tokens, and
    # this is the ONE batched rpm -q call (T-999.47-11) rather than one per
    # package.
    RPM_TABLE=$(rpm_installed_versions $NAMES)

    for ENTRY in $LIST; do
      [ -n "$ENTRY" ] || continue
      NAMEARCH=$(printf '%s\n' "$ENTRY" | awk '{print $1}')
      AVAIL=$(printf '%s\n' "$ENTRY" | awk '{print $2}')
      REPO=$(printf '%s\n' "$ENTRY" | awk '{print $3}')
      NAME=${NAMEARCH%.*}
      ARCH=${NAMEARCH##*.}
      CUR=$(rpm_installed_version_for "$NAME" "$RPM_TABLE")
      MATCH=$(printf '%s\n' "$SECLIST" | grep -m1 -- "${NAME}-" || true)
      if [ -n "$MATCH" ]; then
        SEV=$(printf '%s\n' "$MATCH" | awk '{print $1}' | sed -E 's#/Sec\.?$##' | tr '[:upper:]' '[:lower:]')
        case "$SEV" in
          critical|important) add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true" ;;
          moderate)            add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true" ;;
          low)                 add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true" ;;
          *)                   add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "true" ;;
        esac
      else
        add_package "$NAME" "$ARCH" "$CUR" "$AVAIL" "$REPO" "false"
      fi
    done
    IFS=$OLDIFS
  fi
  needs-restarting -r >/dev/null 2>&1
  [ $? -eq 1 ] && REBOOT=true
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# All three branches (apt, dnf, yum) build $PACKAGES now (999.47-03) -- a
# node with no supported package manager on PATH at all also gets this
# shape, with an empty packages[] array. The legacy patches[] shape is no
# longer emitted by this script; patchFactPackages's fallback to "patches"
# (backend/internal/httpapi/patching.go) remains the only thing that still
# knows it, as the degradation path for any node still running a pre-999.47
# copy of this module during rollout (spec section 7).
printf '{"patchbot": {"available": %s, "security": %s, "reboot_required": %s, "last_checked": "%s", "packages": [%s]}}\n' \
  "${AVAILABLE:-0}" "${SECURITY:-0}" "$REBOOT" "$NOW" "$PACKAGES"
