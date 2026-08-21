#!/bin/sh
# tools/supplychain/scan.sh — static pattern checks for Puppet DSL / Ruby /
# PowerShell content that no off-the-shelf scanner covers: unpinned remote-
# fetch-into-shell execs, undocumented base64 blobs, obfuscated/dynamically-
# eval'd Ruby, and obfuscated/dynamically-eval'd PowerShell in this module's
# custom types/providers/functions/tasks/facts.
#
# Modeled on puppet-console's Go supply-chain gate (tools/supplychain,
# SC-INST-001/SC-INST-002, docs/SUPPLY-CHAIN.md's "no install-time
# execution" control) but is its own small, dependency-free tool for this
# repo's languages (Puppet DSL + Ruby + PowerShell, not Go) -- it shares
# that gate's philosophy (rule ID + threat + remedy, scoped/dated/owned
# waivers that expire rather than a blanket disable, fail closed) but not
# its code. Ported from stagehand's tools/supplychain/scan.sh; patchbot
# adds PSC-INST-004 (PowerShell obfuscation) since, unlike stagehand, this
# module ships real PowerShell content (tasks/patch.ps1,
# facts.d/patchbot.ps1) -- and extends the scanned FILES glob to include
# facts.d/*, which stagehand's reference never needed (stagehand ships no
# facts.d/ at all).
#
# Usage: tools/supplychain/scan.sh [-waivers PATH]
# Exit codes: 0 clean (or every finding waived), 1 one or more live
# findings, 2 tool/config error (not a git repo, malformed waiver file).
#
# Scope: every file `git ls-files` tracks (so build output / .gitignore'd
# fixtures are never scanned, and a checkout outside a worktree fails
# loudly rather than silently scanning nothing).

set -eu

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/../.." && pwd) || die "could not resolve repo root"
cd "$ROOT" || die "could not cd to repo root"

WAIVERS="$ROOT/supplychain.waivers.json"
while [ $# -gt 0 ]; do
  case "$1" in
    -waivers) WAIVERS="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git not found on PATH"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"

TODAY=$(date -u +%Y-%m-%d)

FILES=$(git ls-files -- \
  '*.pp' '*.epp' '*.rb' '*.erb' \
  'tasks/*' 'files/*' 'lib/*' 'facts.d/*' \
  ':!:spec/fixtures/*') || die "git ls-files failed"

FINDINGS_FILE=$(mktemp) || die "mktemp failed"
trap 'rm -f "$FINDINGS_FILE"' EXIT

# --- PSC-INST-001: unpinned remote fetch piped straight into a shell -------
# Same threat model as the Go gate's SC-INST-002 (pipe-to-shell install):
# curl|wget piped to a shell executes whatever the endpoint serves *right
# now*, unpinned and unreviewed -- Bolt tasks in particular can ship
# non-.pp executables, so this scans task/file content, not just execs
# embedded in manifests.
PIPE_TO_SHELL_RE='(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|k|d)?sh\b'

check_pipe_to_shell() {
  file="$1"
  # Strip full-line comments (# for sh/rb, // and /* */-unsupported here --
  # Puppet/Ruby both use #) before matching, so a documented example in a
  # comment doesn't false-positive.
  grep -nE "$PIPE_TO_SHELL_RE" "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS=: read -r lineno _rest; do
    printf 'PSC-INST-001\t%s\t%s\tdownloaded script is piped straight into a shell, unpinned and unverified\tcurl/wget piped to a shell executes whatever the endpoint serves at fetch time -- unpinned, unreviewed, and a different payload on every run.\tDownload to a file, verify a pinned checksum or signature, then execute the file.\n' "$file" "$lineno" >> "$FINDINGS_FILE"
  done
}

# --- PSC-INST-002: base64 blob with no documented reason -------------------
# A long base64-looking literal with no comment explaining what it is and
# why it's there is exactly how a payload hides in a manifest or template.
# "Documented" here means a comment mentioning base64 within 2 lines above
# or on the same line -- cheap, testable, and easy for a real one to pass.
#
# The base64 alphabet is a superset of hex and of path characters, so two
# exclusions are load-bearing, not cosmetic: a pure-hex match (git SHAs,
# sha256 digests) is never base64 payload, and a match containing 2+ `/`
# is a filesystem path/URL, not encoded content -- real base64 output
# distributes `/` far more sparsely (~1 in 64 chars) than a path does.
BASE64_BLOB_RE='[A-Za-z0-9+/]{44,}=?=?'
HEX_ONLY_RE='^[0-9A-Fa-f]+={0,2}$'

check_base64_blobs() {
  file="$1"
  grep -noE "$BASE64_BLOB_RE" "$file" 2>/dev/null | while IFS=: read -r lineno match; do
    printf '%s' "$match" | grep -qE "$HEX_ONLY_RE" && continue
    slash_count=$(printf '%s' "$match" | tr -cd '/' | wc -c | tr -d ' ')
    [ "$slash_count" -ge 2 ] && continue
    start=$((lineno > 2 ? lineno - 2 : 1))
    context=$(sed -n "${start},${lineno}p" "$file" 2>/dev/null)
    case "$context" in
      *'#'*[Bb]ase64*) : ;; # documented -- has a nearby comment mentioning base64
      *)
        printf 'PSC-INST-002\t%s\t%s\tbase64-looking blob with no nearby comment explaining what it is\tAn undocumented base64 blob is how a payload hides in plain sight in a manifest or template -- it reads as "config" until decoded.\tAdd a comment on or immediately above the line saying what the blob is and why it must be base64 (e.g. a binary cert/key), or replace it with a real file() reference.\n' "$file" "$lineno" >> "$FINDINGS_FILE"
        ;;
    esac
  done
}

# --- PSC-INST-003: obfuscated / dynamically-eval'd Ruby ---------------------
# eval/instance_eval/class_eval/Marshal.load run arbitrary code constructed
# at runtime rather than reviewed at commit time; send()/public_send() with
# a non-literal method name (a variable or a computed expression instead of
# a bare :symbol or "string") is the same shape one layer removed -- both
# are how a custom type/provider/function smuggles logic past a code review
# that only reads the literal source.
EVAL_RE='\b(eval|instance_eval|class_eval|module_eval|Marshal\.load)[[:space:]]*\('
DYNAMIC_SEND_RE='\b(public_)?send[[:space:]]*\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[,)]'

check_obfuscated_ruby() {
  file="$1"
  case "$file" in
    *.rb) : ;;
    *) return 0 ;;
  esac
  grep -nE "$EVAL_RE" "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS=: read -r lineno _rest; do
    printf 'PSC-INST-003\t%s\t%s\tdynamic eval (eval/instance_eval/class_eval/module_eval/Marshal.load)\tCode built and executed at runtime cannot be read at review time -- it is the Ruby-side equivalent of a pipe-to-shell install.\tReplace with an explicit, literal call. If genuinely required (rare), scope it as tightly as possible and get a second reviewer on that line specifically.\n' "$file" "$lineno" >> "$FINDINGS_FILE"
  done
  grep -nE "$DYNAMIC_SEND_RE" "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS=: read -r lineno _rest; do
    printf 'PSC-INST-003\t%s\t%s\tsend/public_send with a non-literal method name\tA computed method name means the actual method invoked is not visible in the source -- the same "logic hides behind an indirection" shape as eval, just one call deeper.\tCall the method directly, or if truly dynamic, validate the name against an explicit allowlist before sending.\n' "$file" "$lineno" >> "$FINDINGS_FILE"
  done
}

# --- PSC-INST-004: obfuscated / dynamically-eval'd PowerShell --------------
# Invoke-Expression/IEX runs a string as code, built at runtime -- the
# PowerShell-side equivalent of PSC-INST-003's Ruby eval. -EncodedCommand
# (and its unambiguous abbreviations -e/-en/-enc down to the shortest
# non-conflicting prefix PowerShell.exe accepts) passes a base64-encoded
# script on the command line specifically so the plaintext never appears in
# a process listing or a naive grep -- a textbook obfuscation shape, not
# just an equivalent-severity one. Both are how a task/fact smuggles logic
# past a code review that only reads the literal source. Scoped to *.ps1
# files only, same "only scan the language this rule concerns" pattern as
# check_obfuscated_ruby's *.rb guard.
PS_INVOKE_EXPR_RE='\b(Invoke-Expression|IEX)\b'
PS_ENCODED_CMD_RE='-[Ee]([Nn]([Cc]([Oo]([Dd]([Ee]([Dd]([Cc]([Oo]([Mm]([Mm]([Aa][Nn][Dd]?)?)?)?)?)?)?)?)?)?)?)?\b'

check_obfuscated_powershell() {
  file="$1"
  case "$file" in
    *.ps1) : ;;
    *) return 0 ;;
  esac
  grep -nE "$PS_INVOKE_EXPR_RE" "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS=: read -r lineno _rest; do
    printf 'PSC-INST-004\t%s\t%s\tInvoke-Expression/IEX (dynamic code execution from a string)\tCode built and executed at runtime cannot be read at review time -- it is the PowerShell-side equivalent of a pipe-to-shell install or Ruby eval.\tReplace with an explicit, literal call. If genuinely required (rare), scope it as tightly as possible and get a second reviewer on that line specifically.\n' "$file" "$lineno" >> "$FINDINGS_FILE"
  done
  # -- terminates option parsing: the pattern itself starts with a literal
  # `-` (matching -EncodedCommand), which grep would otherwise try to parse
  # as its own option flags rather than pattern text.
  grep -nE -- "$PS_ENCODED_CMD_RE" "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS=: read -r lineno _rest; do
    printf 'PSC-INST-004\t%s\t%s\t-EncodedCommand (base64-encoded script passed on the command line)\tThe plaintext script is deliberately absent from the command line and process listing -- the standard technique for hiding a PowerShell payload from casual inspection.\tPass the script as a literal .ps1 file argument instead of an encoded command string. If genuinely required (rare), scope it as tightly as possible and get a second reviewer on that line specifically.\n' "$file" "$lineno" >> "$FINDINGS_FILE"
  done
}

for f in $FILES; do
  [ -f "$f" ] || continue
  check_pipe_to_shell "$f"
  check_base64_blobs "$f"
  check_obfuscated_ruby "$f"
  check_obfuscated_powershell "$f"
done

# --- waiver matching ---------------------------------------------------
# Scoped (rule + optional path glob + optional substring), owned, and
# expiring -- an exception nobody re-reads is a permanent hole with a
# comment on it. Parsed with a tiny inline Ruby/python-free jq-or-python
# fallback so this script stays dependency-free; prefer python3 (present
# on every CI runner image) over hand-rolled shell JSON parsing.
waiver_lookup() {
  # $1=rule $2=file $3=detail -> prints "OWNER\tEXPIRES\tREASON" if a live
  # (non-expired) waiver matches, "EXPIRED\tEXPIRES\tREASON" if a matching
  # waiver has lapsed, or nothing if no waiver matches at all.
  [ -f "$WAIVERS" ] || return 0
  command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH (needed to parse $WAIVERS)"
  python3 - "$WAIVERS" "$1" "$2" "$3" "$TODAY" <<'PYEOF'
import json, sys, fnmatch
waivers_path, rule, path, detail, today = sys.argv[1:6]
try:
    with open(waivers_path) as fh:
        waivers = json.load(fh)
except (OSError, json.JSONDecodeError) as e:
    print(f"ERROR: malformed waiver file {waivers_path}: {e}", file=sys.stderr)
    sys.exit(2)
for w in waivers:
    for req in ("rule", "reason", "owner", "expires"):
        if req not in w:
            print(f"ERROR: waiver missing required field '{req}': {w}", file=sys.stderr)
            sys.exit(2)
    if w["rule"] != rule:
        continue
    if "path" in w and not fnmatch.fnmatch(path, w["path"]):
        continue
    if "contains" in w and w["contains"] not in detail:
        continue
    status = "EXPIRED" if w["expires"] < today else w["owner"]
    print(f"{status}\t{w['expires']}\t{w['reason']}")
    sys.exit(0)
PYEOF
}

LIVE_COUNT=0
WAIVED_COUNT=0

if [ -s "$FINDINGS_FILE" ]; then
  while IFS='	' read -r rule file lineno title threat remedy; do
    printf '[%s] %s:%s: %s\n' "$rule" "$file" "$lineno" "$title"
    printf '  Threat: %s\n' "$threat"
    printf '  Remedy: %s\n' "$remedy"
    WAIVER_OUT=$(waiver_lookup "$rule" "$file" "$title") || exit 2
    if [ -n "$WAIVER_OUT" ]; then
      w_owner=$(printf '%s' "$WAIVER_OUT" | cut -f1)
      w_expires=$(printf '%s' "$WAIVER_OUT" | cut -f2)
      w_reason=$(printf '%s' "$WAIVER_OUT" | cut -f3)
      if [ "$w_owner" = "EXPIRED" ]; then
        printf '  WAIVER EXPIRED %s -- treating as a live finding: %s\n' "$w_expires" "$w_reason"
        LIVE_COUNT=$((LIVE_COUNT + 1))
      else
        printf '  WAIVED by %s until %s: %s\n' "$w_owner" "$w_expires" "$w_reason"
        WAIVED_COUNT=$((WAIVED_COUNT + 1))
      fi
    else
      LIVE_COUNT=$((LIVE_COUNT + 1))
    fi
    printf '\n'
  done < "$FINDINGS_FILE"
fi

TOTAL=$((LIVE_COUNT + WAIVED_COUNT))
printf 'supplychain scan.sh: %d finding(s), %d waived, %d live\n' "$TOTAL" "$WAIVED_COUNT" "$LIVE_COUNT"

if [ "$LIVE_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
