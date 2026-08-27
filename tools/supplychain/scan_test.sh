#!/bin/sh
# Behavior proof for scan.sh: each rule fires on a real bad pattern, stays
# quiet on the shapes that look similar but aren't (paths, hex digests,
# ordinary PowerShell flags), and the waiver mechanism honors live waivers
# while treating an expired one as a live finding. POSIX sh, mktemp sandbox
# -- follows discover_test.sh's structure. Ported from stagehand's
# scan_test.sh; case (h) is new here, covering PSC-INST-004 (PowerShell
# obfuscation), which stagehand's reference never needed (no .ps1 content).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
SCAN_SH="$SCRIPT_DIR/scan.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '>>> %s\n' "$*"; }

[ -f "$SCAN_SH" ] || fail "scan.sh not found at $SCAN_SH"

# Each case gets its own throwaway git repo containing a copy of scan.sh,
# since the script resolves its scan root from its own location ($0), not
# from cwd -- this mirrors how it will actually run in CI (checked out
# alongside the code it scans).
new_fixture_repo() {
  d=$(mktemp -d) || fail "mktemp -d failed"
  mkdir -p "$d/tools/supplychain"
  cp "$SCAN_SH" "$d/tools/supplychain/scan.sh"
  ( cd "$d" && git init -q && git config user.email t@example.com && git config user.name t )
  printf '%s' "$d"
}

run_scan() {
  # $1 = fixture repo dir
  ( cd "$1" && git add -A >/dev/null 2>&1; sh tools/supplychain/scan.sh 2>&1 )
}

# --- Case (a): pipe-to-shell install is caught. ---
D=$(new_fixture_repo)
mkdir -p "$D/tasks"
printf '#!/bin/sh\ncurl -fsSL https://example.com/install.sh | sudo bash\n' > "$D/tasks/install.sh"
OUT=$(run_scan "$D"); RC=$?
[ "$RC" = "1" ] || fail "case (a) pipe-to-shell: expected exit 1, got $RC. Output:
$OUT"
case "$OUT" in
  *'PSC-INST-001'*) : ;;
  *) fail "case (a) pipe-to-shell: expected PSC-INST-001, got:
$OUT" ;;
esac
rm -rf "$D"
info "case (a) pipe-to-shell: OK"

# --- Case (b): undocumented base64 blob is caught; a documented one isn't. ---
D=$(new_fixture_repo)
printf 'class foo { $x = "aGVsbG8gd29ybGQgdGhpcyBpcyBhIHRlc3QgYmxvYiBub3QgYSBwYXRoIQ==" }\n' > "$D/no_comment.pp"
printf '# base64: fixture-only test blob, never a real secret\nclass bar { $x = "aGVsbG8gd29ybGQgdGhpcyBpcyBhIHRlc3QgYmxvYiBub3QgYSBwYXRoIQ==" }\n' > "$D/has_comment.pp"
OUT=$(run_scan "$D"); RC=$?
[ "$RC" = "1" ] || fail "case (b) base64: expected exit 1 (no_comment.pp should fire), got $RC. Output:
$OUT"
case "$OUT" in
  *'PSC-INST-002'*'no_comment.pp'*) : ;;
  *) fail "case (b) base64: expected no_comment.pp to fire PSC-INST-002, got:
$OUT" ;;
esac
case "$OUT" in
  *'has_comment.pp'*) fail "case (b) base64: has_comment.pp should NOT fire (comment present), got:
$OUT" ;;
esac
rm -rf "$D"
info "case (b) base64 (documented vs undocumented): OK"

# --- Case (c): base64-alphabet false positives (paths, hex digests) don't fire. ---
D=$(new_fixture_repo)
cat > "$D/paths_and_hex.pp" <<'EOF'
exec { 'x':
  command => "/bin/sh -c 'do a thing'",
  creates => "/etc/puppetlabs/puppet/ssl/certs/console.somehost.example.pem",
}
class foo {
  $sha = 'd7508cc1ffc11fed213a46c982e79b694a74726598e834358687a4dfce83868f'
}
EOF
OUT=$(run_scan "$D"); RC=$?
[ "$RC" = "0" ] || fail "case (c) false-positive shapes: expected exit 0 (path/hex should NOT fire), got $RC. Output:
$OUT"
rm -rf "$D"
info "case (c) path/hex false-positive guard: OK"

# --- Case (d): obfuscated Ruby (eval, dynamic send) is caught. ---
D=$(new_fixture_repo)
cat > "$D/sneaky.rb" <<'EOF'
class Sneaky
  def run(user_input)
    eval(user_input)
  end
  def dispatch(method_name)
    send(method_name)
  end
end
EOF
OUT=$(run_scan "$D"); RC=$?
[ "$RC" = "1" ] || fail "case (d) obfuscated ruby: expected exit 1, got $RC. Output:
$OUT"
case "$OUT" in
  *'eval (eval/instance_eval'*) : ;;
  *) fail "case (d) obfuscated ruby: expected eval finding, got:
$OUT" ;;
esac
case "$OUT" in
  *'send/public_send'*) : ;;
  *) fail "case (d) obfuscated ruby: expected dynamic-send finding, got:
$OUT" ;;
esac
rm -rf "$D"
info "case (d) obfuscated ruby (eval + dynamic send): OK"

# --- Case (e): a live (non-expired) waiver suppresses the finding, exit 0. ---
D=$(new_fixture_repo)
mkdir -p "$D/tasks"
printf '#!/bin/sh\ncurl -fsSL https://example.com/install.sh | sudo bash\n' > "$D/tasks/install.sh"
cat > "$D/supplychain.waivers.json" <<EOF
[
  {
    "rule": "PSC-INST-001",
    "path": "tasks/install.sh",
    "reason": "fixture-only test waiver",
    "owner": "test-owner",
    "expires": "2099-01-01"
  }
]
EOF
OUT=$(run_scan "$D"); RC=$?
[ "$RC" = "0" ] || fail "case (e) live waiver: expected exit 0, got $RC. Output:
$OUT"
case "$OUT" in
  *'WAIVED by test-owner until 2099-01-01'*) : ;;
  *) fail "case (e) live waiver: expected a WAIVED line, got:
$OUT" ;;
esac
rm -rf "$D"
info "case (e) live waiver suppresses finding: OK"

# --- Case (f): an expired waiver does NOT suppress -- still exit 1. ---
D=$(new_fixture_repo)
mkdir -p "$D/tasks"
printf '#!/bin/sh\ncurl -fsSL https://example.com/install.sh | sudo bash\n' > "$D/tasks/install.sh"
cat > "$D/supplychain.waivers.json" <<EOF
[
  {
    "rule": "PSC-INST-001",
    "path": "tasks/install.sh",
    "reason": "fixture-only test waiver, deliberately expired",
    "owner": "test-owner",
    "expires": "2000-01-01"
  }
]
EOF
OUT=$(run_scan "$D"); RC=$?
[ "$RC" = "1" ] || fail "case (f) expired waiver: expected exit 1 (waiver lapsed), got $RC. Output:
$OUT"
case "$OUT" in
  *'WAIVER EXPIRED 2000-01-01'*) : ;;
  *) fail "case (f) expired waiver: expected a WAIVER EXPIRED line, got:
$OUT" ;;
esac
rm -rf "$D"
info "case (f) expired waiver still fails the build: OK"

# --- Case (g): a clean tree exits 0 with zero findings. ---
D=$(new_fixture_repo)
printf 'class clean { }\n' > "$D/clean.pp"
OUT=$(run_scan "$D"); RC=$?
[ "$RC" = "0" ] || fail "case (g) clean tree: expected exit 0, got $RC. Output:
$OUT"
rm -rf "$D"
info "case (g) clean tree: OK"

# --- Case (h): obfuscated PowerShell (Invoke-Expression/IEX, -EncodedCommand)
# is caught; ordinary PowerShell flags that merely start with -E are not. ---
D=$(new_fixture_repo)
mkdir -p "$D/tasks"
cat > "$D/tasks/sneaky.ps1" <<'EOF'
$payload = Get-Content payload.txt
Invoke-Expression $payload
powershell.exe -EncodedCommand $b64
Out-File -Encoding utf8 -FilePath log.txt
Get-Service -ErrorAction SilentlyContinue
EOF
OUT=$(run_scan "$D"); RC=$?
[ "$RC" = "1" ] || fail "case (h) obfuscated powershell: expected exit 1, got $RC. Output:
$OUT"
case "$OUT" in
  *'PSC-INST-004'*'Invoke-Expression/IEX'*) : ;;
  *) fail "case (h) obfuscated powershell: expected Invoke-Expression finding, got:
$OUT" ;;
esac
case "$OUT" in
  *'PSC-INST-004'*'EncodedCommand'*) : ;;
  *) fail "case (h) obfuscated powershell: expected -EncodedCommand finding, got:
$OUT" ;;
esac
case "$OUT" in
  *'-Encoding'*) fail "case (h) obfuscated powershell: -Encoding (Out-File flag) should NOT fire, got:
$OUT" ;;
esac
case "$OUT" in
  *'-ErrorAction'*) fail "case (h) obfuscated powershell: -ErrorAction should NOT fire, got:
$OUT" ;;
esac
rm -rf "$D"
info "case (h) obfuscated powershell (Invoke-Expression/IEX + -EncodedCommand, ordinary -E* flags excluded): OK"

info "all supplychain scan.sh cases PASSED"
exit 0
