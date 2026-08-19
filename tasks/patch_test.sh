#!/bin/sh
# patchbot::patch test harness (02-01-PLAN.md Task 1). Follows
# install_ansible_test.sh's structure: mktemp sandbox, PATH-shimmed
# apt-get/dnf/yum stubs that record their own invocation, a curated PATH,
# and exit-code/content assertions. patch.json's input_method is
# "environment" (not stdin), so params are fed via PT_* env vars, not JSON
# on stdin -- unlike install_ansible_test.sh/run_playbook_test.sh's
# stdin-JSON convention.
#
# Cases (see 02-01-PLAN.md Task 1 <behavior>):
#   (1) patch_ids=["--allow-downgrades"] rejected -> exit 1, stderr message,
#       apt-get/dnf/yum stub NEVER invoked (AUDIT-01 regression, d5c383f).
#   (2) patch_ids=["foo --reinstall"] (embedded whitespace) rejected the
#       same way (regression).
#   (3) simulated apt-get update failure -> embedded JSON error, exit 0
#       (AUDIT-04).
#   (4) simulated apt-get dist-upgrade failure -> embedded JSON error,
#       exit 0 (AUDIT-04).
#   (5) no supported package manager on PATH -> embedded JSON error,
#       exit 0 (AUDIT-04).
#   (6) success path (apt-get stub succeeds) -> unchanged success JSON
#       shape, exit 0 (regression).
#   (7) patch.json's ingest_token.sensitive is true (AUDIT-03).
#   (8) patch.json's top-level input_method is "both" (AUDIT-03).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
TARGET_SH="$SCRIPT_DIR/patch.sh"
TARGET_JSON="$SCRIPT_DIR/patch.json"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '>>> %s\n' "$*"; }

[ -f "$TARGET_SH" ] || fail "patch.sh not found at $TARGET_SH"
[ -f "$TARGET_JSON" ] || fail "patch.json not found at $TARGET_JSON"
command -v jq >/dev/null 2>&1 || fail "jq is required to run this test harness"

WORK=$(mktemp -d) || fail "mktemp -d failed"
trap 'rm -rf "$WORK"' EXIT

SHIMDIR="$WORK/shims"
mkdir -p "$SHIMDIR" || fail "could not create shim dir"

ARGV_LOG="$WORK/argv.log"
export ARGV_LOG

REAL_JQ=$(command -v jq) || fail "no real jq on PATH to reference"

# make_pm_stub NAME FAIL_FLAG_VAR
# Writes a PATH shim for NAME that logs "NAME <argv>" to ARGV_LOG. If
# FAIL_FLAG_VAR is exported "1", the shim exits 1 (simulating that
# subcommand failing); otherwise it exits 0. patch.sh calls the same
# binary (e.g. apt-get) multiple times with different subcommands
# (update, then install/dist-upgrade) -- FAIL_FLAG_VAR fails EVERY
# invocation of that binary, which is sufficient to reach the first
# die()/fail_json() call site in each dispatch branch.
make_pm_stub() {
  name="$1"
  fail_var="$2"
  cat > "$SHIMDIR/$name" <<SHIM
#!/bin/sh
printf '$name %s\n' "\$*" >> "$ARGV_LOG"
if [ "\${$fail_var:-0}" = "1" ]; then
  exit 1
fi
exit 0
SHIM
  chmod +x "$SHIMDIR/$name"
}

make_pm_stub apt-get SHIM_APT_FAIL

# TEST_PATH includes the shim dir first, then the real jq's directory (so
# patch.sh's jq-presence/parse checks keep working against a real jq), then
# a minimal system PATH WITHOUT dnf/yum/apt-get from the real system (this
# host has none of those, being macOS, so no exclusion needed beyond not
# adding them).
JQ_DIR=$(dirname "$REAL_JQ")
TEST_PATH="$SHIMDIR:$JQ_DIR:/usr/bin:/bin"

# NOPM_PATH: a PATH with none of apt-get/dnf/yum present, but jq still
# reachable (for case 5: "no supported package manager").
NOPM_PATH="$JQ_DIR:/usr/bin:/bin"

run_patch() {
  # shellcheck disable=SC2086
  env -i \
    PATH="$TEST_PATH" \
    HOME="$HOME" \
    ARGV_LOG="$ARGV_LOG" \
    ${PT_patch_ids:+PT_patch_ids="$PT_patch_ids"} \
    ${PT_security_only:+PT_security_only="$PT_security_only"} \
    ${PT_reboot:+PT_reboot="$PT_reboot"} \
    SHIM_APT_FAIL="${SHIM_APT_FAIL:-0}" \
    sh "$TARGET_SH"
}

reset() {
  : > "$ARGV_LOG"
  unset PT_patch_ids PT_security_only PT_reboot
  SHIM_APT_FAIL=0
}

# --- Case 1: patch_ids=["--allow-downgrades"] rejected. ---
reset
PT_patch_ids='["--allow-downgrades"]'
OUT=$(run_patch 2>"$WORK/stderr.1")
RC=$?
STDERR=$(cat "$WORK/stderr.1")
[ "$RC" -eq 1 ] || fail "case 1 (--allow-downgrades): expected exit 1, got $RC. stdout: $OUT"
case "$STDERR" in
  *'patch_ids contains an invalid identifier'*) : ;;
  *) fail "case 1 (--allow-downgrades): expected stderr to contain 'patch_ids contains an invalid identifier', got: $STDERR" ;;
esac
[ -s "$ARGV_LOG" ] && fail "case 1 (--allow-downgrades): apt-get stub was invoked but should not have been. argv log:
$(cat "$ARGV_LOG")"
info "case 1 (--allow-downgrades): OK (exit 1, rejected, stub never invoked)"

# --- Case 2: patch_ids=["foo --reinstall"] (embedded whitespace) rejected. ---
reset
PT_patch_ids='["foo --reinstall"]'
OUT=$(run_patch 2>"$WORK/stderr.2")
RC=$?
STDERR=$(cat "$WORK/stderr.2")
[ "$RC" -eq 1 ] || fail "case 2 (embedded whitespace): expected exit 1, got $RC. stdout: $OUT"
case "$STDERR" in
  *'patch_ids contains an invalid identifier'*) : ;;
  *) fail "case 2 (embedded whitespace): expected stderr to contain 'patch_ids contains an invalid identifier', got: $STDERR" ;;
esac
[ -s "$ARGV_LOG" ] && fail "case 2 (embedded whitespace): apt-get stub was invoked but should not have been. argv log:
$(cat "$ARGV_LOG")"
info "case 2 (embedded whitespace): OK (exit 1, rejected, stub never invoked)"

# --- Case 3: simulated apt-get update failure -> embedded JSON error, exit 0. ---
reset
SHIM_APT_FAIL=1
OUT=$(run_patch)
RC=$?
[ "$RC" -eq 0 ] || fail "case 3 (apt-get update failure): expected exit 0, got $RC. stdout: $OUT"
[ "$OUT" = '{"status": "error", "error": "apt-get update failed"}' ] \
  || fail "case 3 (apt-get update failure): unexpected stdout: $OUT"
info "case 3 (apt-get update failure): OK (embedded JSON error, exit 0)"

# --- Case 4: simulated apt-get dist-upgrade failure -> embedded JSON error, exit 0. ---
# apt-get update must succeed but dist-upgrade must fail: use a stub that
# fails only on non-update subcommands.
reset
cat > "$SHIMDIR/apt-get" <<SHIM
#!/bin/sh
printf 'apt-get %s\n' "\$*" >> "$ARGV_LOG"
case "\$1" in
  -qq) exit 0 ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$SHIMDIR/apt-get"
OUT=$(run_patch)
RC=$?
[ "$RC" -eq 0 ] || fail "case 4 (apt-get dist-upgrade failure): expected exit 0, got $RC. stdout: $OUT"
[ "$OUT" = '{"status": "error", "error": "apt dist-upgrade failed"}' ] \
  || fail "case 4 (apt-get dist-upgrade failure): unexpected stdout: $OUT"
make_pm_stub apt-get SHIM_APT_FAIL
info "case 4 (apt-get dist-upgrade failure): OK (embedded JSON error, exit 0)"

# --- Case 5: no supported package manager on PATH -> embedded JSON error, exit 0. ---
reset
OUT=$(env -i PATH="$NOPM_PATH" HOME="$HOME" sh "$TARGET_SH")
RC=$?
[ "$RC" -eq 0 ] || fail "case 5 (no package manager): expected exit 0, got $RC. stdout: $OUT"
[ "$OUT" = '{"status": "error", "error": "no supported package manager (apt/dnf/yum) found"}' ] \
  || fail "case 5 (no package manager): unexpected stdout: $OUT"
info "case 5 (no package manager): OK (embedded JSON error, exit 0)"

# --- Case 6: success path (apt-get stub succeeds) -> unchanged success JSON shape. ---
reset
SHIM_APT_FAIL=0
OUT=$(run_patch)
RC=$?
[ "$RC" -eq 0 ] || fail "case 6 (success): expected exit 0, got $RC. stdout: $OUT"
[ "$OUT" = '{"status": "patched", "applied": "all", "reboot_required": false, "rebooted": false}' ] \
  || fail "case 6 (success): unexpected stdout: $OUT"
grep -q '^apt-get -qq update' "$ARGV_LOG" || fail "case 6 (success): apt-get update was not invoked. argv log:
$(cat "$ARGV_LOG")"
info "case 6 (success): OK (unchanged success JSON shape, exit 0)"

# --- Case 7: patch.json's ingest_token.sensitive is true (AUDIT-03). ---
SENSITIVE=$("$REAL_JQ" -r '.parameters.ingest_token.sensitive' "$TARGET_JSON")
[ "$SENSITIVE" = "true" ] || fail "case 7 (ingest_token sensitive): expected \"true\", got: $SENSITIVE"
info "case 7 (ingest_token sensitive): OK"

# --- Case 8: patch.json's top-level input_method is "both" (AUDIT-03). ---
INPUT_METHOD=$("$REAL_JQ" -r '.input_method' "$TARGET_JSON")
[ "$INPUT_METHOD" = "both" ] || fail "case 8 (input_method both): expected \"both\", got: $INPUT_METHOD"
info "case 8 (input_method both): OK"

info "all patch.sh/patch.json safety cases PASSED"
exit 0
