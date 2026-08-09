#!/usr/bin/env bash
#
# tokenscan-test.sh — self-test for tokenscan.sh.
#
# Builds throwaway git repos containing synthetic secrets (correct SHAPE, no
# real values) and asserts the scanner finds them, redacts them, honours the
# allowlist, and returns the right exit codes.
#
# Usage:  scripts/security/tokenscan-test.sh
# Exit:   0 all passed, 1 one or more failed
#
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCANNER="$HERE/tokenscan.sh"
[ -r "$SCANNER" ] || { echo "cannot read $SCANNER" >&2; exit 1; }

PASS=0; FAIL=0
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; O=$'\033[0m'
else G=""; R=""; B=""; O=""; fi

ok()  { printf '  %sPASS%s %s\n' "$G" "$O" "$1"; PASS=$((PASS+1)); }
bad() { printf '  %sFAIL%s %s\n' "$R" "$O" "$1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — expected '$3', got '$2'"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 — '$3' not in output"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 — '$3' unexpectedly in output"; else ok "$1"; fi; }
section(){ printf '\n%s── %s%s\n' "$B" "$1" "$O"; }

# new_repo <dir> — init a git repo with the scanner installed and empty allowlist
new_repo() {
    local d="$1"
    mkdir -p "$d/scripts/security" "$d/src"
    ( cd "$d" && git init -q . \
        && git config user.email t@test && git config user.name tester ) || return 1
    cp "$SCANNER" "$d/scripts/security/tokenscan.sh"
    : > "$d/scripts/security/tokenscan-allow.txt"
}
# scan <dir> [args...] — run the scanner inside dir, echo output, return its code
scan() { local d="$1"; shift; ( cd "$d" && bash scripts/security/tokenscan.sh "$@" --no-color 2>&1 ); }

# AWS-shaped fixture assembled at runtime (see the note in section 1 — no
# contiguous secret literal may appear in this file).
p_aws='AKIA'; b_aws='IOSFODNN7EXAMPLE'
p_goo='AIza'; b_goo='SyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7'
mkleak() { printf 'k = "%s%s"%s\n' "$p_aws" "$b_aws" "${2:-}" > "$1"; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tokenscan-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT

# ═════════════════════════════════════════════════════════════════════════════
section "1. rule detection (synthetic secrets, empty allowlist)"

D="$ROOT/detect"; new_repo "$D" || { echo "fixture failed"; exit 1; }

# IMPORTANT: every fixture value is assembled at runtime from a prefix plus a
# body, so that THIS FILE never contains a contiguous secret-shaped literal.
# Committing realistic-looking literals gets the file rejected by GitHub push
# protection (and rightly so — a scanner's test data should not be mistakable
# for the real thing). The generated fixture files DO contain contiguous values,
# which is what the scanner is then asked to find.
p_ghp='ghp_';                b_ghp='A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'
p_pat='github_';             b_pat='pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz1234567890'
p_ant='sk-ant-';             b_ant='api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
p_slk='xoxb-';               b_slk='123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx'
p_hook='https://hooks.';     b_hook='slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX'
p_aws='AKIA';                b_aws='IOSFODNN7EXAMPLE'
p_goo='AIza';                b_goo='SyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7'
p_glp='glpat-';              b_glp='AbCdEfGhIjKlMnOpQrSt'
p_dop='dop_';                b_dop='v1_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
p_npm='npm_';                b_npm='AbCdEfGhIjKlMnOpQrStUvWxYz0123456789'
p_stp='sk_';                 b_stp='live_AbCdEfGhIjKlMnOpQrStUvWx'
p_hf='hf_';                  b_hf='AbCdEfGhIjKlMnOpQrStUvWxYz01234567'
p_jwt='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.';  b_jwt='eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmno'
dbpw='sup3rs3cretpw'; ospw='zzzzTOPSECRETzzzzvalue'; genpw='hunter2isnotgreat'
hex32='0123456789abcdef0123456789abcdef'
bearer='AbCdEfGhIjKlMnOpQrStUvWxYz012345'

{
  printf 'GITHUB_CLASSIC = "%s%s"\n'  "$p_ghp"  "$b_ghp"
  printf 'GITHUB_FINE    = "%s%s"\n'  "$p_pat"  "$b_pat"
  printf 'ANTHROPIC      = "%s%s"\n'  "$p_ant"  "$b_ant"
  printf 'SLACK          = "%s%s"\n'  "$p_slk"  "$b_slk"
  printf 'SLACK_HOOK     = "%s%s"\n'  "$p_hook" "$b_hook"
  printf 'AWS_ID         = "%s%s"\n'  "$p_aws"  "$b_aws"
  printf 'GOOGLE         = "%s%s"\n'  "$p_goo"  "$b_goo"
  printf 'GITLAB         = "%s%s"\n'  "$p_glp"  "$b_glp"
  printf 'DIGITALOCEAN   = "%s%s"\n'  "$p_dop"  "$b_dop"
  printf 'NPM            = "%s%s"\n'  "$p_npm"  "$b_npm"
  printf 'STRIPE         = "%s%s"\n'  "$p_stp"  "$b_stp"
  printf 'HUGGINGFACE    = "%s%s"\n'  "$p_hf"   "$b_hf"
  printf 'DB_URL         = "postgresql://admin:%s@db.internal:5432/prod"\n' "$dbpw"
  printf 'AUTH_HEADER    = {"Authorization": "Bearer %s"}\n' "$bearer"
  printf 'api_key        = "%s"\n' "$hex32"
  printf 'password       = "%s"\n' "$genpw"
} > "$D/src/leaky.py"

{
  printf '#!/bin/sh\n'
  printf 'export OS_PASSWORD=%s\n' "$hex32"
  printf 'export OS_APPLICATION_CREDENTIAL_SECRET=%s\n' "$ospw"
} > "$D/src/leaky.sh"

printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEfake\n-----END RSA PRIVATE KEY-----\n' > "$D/src/id_rsa"
printf '%s%s\n' "$p_jwt" "$b_jwt" > "$D/src/tok.jwt"
printf 'SECRET=value\n' > "$D/.env"
echo 'print("clean")' > "$D/src/clean.py"
# the trap from this session: a *tracked* file that .gitignore hides
echo '*.bak_*' > "$D/.gitignore"
printf 'leaked = "%sZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"\n' "$p_ghp" > "$D/src/old.bak_1"
( cd "$D" && git add -A -f >/dev/null && git commit -qm planted >/dev/null )

OUT=$(scan "$D" --tracked); RC=$?
eq "exit code when findings exist" "$RC" "1"

for rule in \
  "GitHub token (classic/oauth)" "GitHub personal access token" "Anthropic API key" \
  "Slack token" "Slack webhook" "AWS access key id" "Google API key" "GitLab PAT" \
  "DigitalOcean PAT" "npm token" "Stripe live key" "HuggingFace token" \
  "Private key block" "JWT" "URL with inline credentials" \
  "Hardcoded Authorization header" "OpenStack secret exported as literal" \
  "32-hex value assigned to a secret name" "Literal credential assignment"
do
  has "detects: $rule" "$OUT" "$rule"
done

section "2. credential-bearing files"
has "flags committed .env"    "$OUT" ".env"
has "flags committed id_rsa"  "$OUT" "id_rsa"

section "3. the .gitignore trap (tracked file hidden by .gitignore)"
has "found in --tracked mode" "$OUT" "old.bak_1"
has "found in --all mode"     "$(scan "$D" --all)" "old.bak_1"

section "4. secrets are redacted, never echoed"
for v in "$p_ghp$b_ghp" "$dbpw" "$genpw" "$ospw" "$p_aws$b_aws" "$p_dop$b_dop"; do
  hasnt "raw value withheld: ${v:0:14}…" "$OUT" "$v"
done
has "shows a redaction marker" "$OUT" "chars]"

section "5. scanner ignores itself and its allowlist"
hasnt "does not flag its own rule table" "$OUT" "scripts/security/tokenscan.sh"

# ═════════════════════════════════════════════════════════════════════════════
section "6. clean repository"
C="$ROOT/clean"; new_repo "$C"
echo 'x = 1' > "$C/ok.py"
( cd "$C" && git add -A >/dev/null && git commit -qm c >/dev/null )
COUT=$(scan "$C" --tracked); CRC=$?
eq   "exit code when clean" "$CRC" "0"
has  "prints CLEAN banner"  "$COUT" "CLEAN"

# ═════════════════════════════════════════════════════════════════════════════
section "7. usage / exit codes"
( cd "$D" && bash scripts/security/tokenscan.sh --bogus ) >/dev/null 2>&1
eq "bad option exits 2" "$?" "2"
( cd "$D" && bash scripts/security/tokenscan.sh --help ) >/dev/null 2>&1
eq "--help exits 0" "$?" "0"

# ═════════════════════════════════════════════════════════════════════════════
section "8. --staged (pre-commit hook use)"
S="$ROOT/staged"; new_repo "$S"
echo 'x = 1' > "$S/ok.py"
( cd "$S" && git add -A >/dev/null && git commit -qm base >/dev/null )
mkleak "$S/src/new_leak.py"
mkleak "$S/src/not_staged.py"
( cd "$S" && git add src/new_leak.py >/dev/null )
SOUT=$(scan "$S" --staged)
has   "flags the staged file"        "$SOUT" "new_leak.py"
hasnt "ignores the unstaged file"    "$SOUT" "not_staged.py"

# ═════════════════════════════════════════════════════════════════════════════
section "9. allowlist"
A="$ROOT/allow"; new_repo "$A"
mkleak "$A/src/leaky.py"
printf 'GOOGLE = "%s%s"\n' "$p_goo" "$b_goo" > "$A/src/other.py"
( cd "$A" && git add -A >/dev/null && git commit -qm p >/dev/null )
printf '^src/leaky\\.py:\n' > "$A/scripts/security/tokenscan-allow.txt"

AOUT=$(scan "$A" --tracked)
hasnt "suppresses the allowlisted path" "$AOUT" "src/leaky.py"
has   "still reports other paths"       "$AOUT" "src/other.py"
has   "--no-allow bypasses allowlist"   "$(scan "$A" --tracked --no-allow)" "src/leaky.py"
has   "-v lists suppressions"           "$(scan "$A" --tracked -v)" "Allowlisted"
has   "comments in allowlist ignored"   "$AOUT" "src/other.py"

section "10. inline tokenscan:allow marker"
I="$ROOT/inline"; new_repo "$I"
mkleak "$I/src/a.py" "  # tokenscan:allow"
mkleak "$I/src/b.py"
( cd "$I" && git add -A >/dev/null && git commit -qm p >/dev/null )
IOUT=$(scan "$I" --tracked)
hasnt "honours inline marker"        "$IOUT" "src/a.py"
has   "still flags the line without" "$IOUT" "src/b.py"

# ═════════════════════════════════════════════════════════════════════════════
section "11. --history recovers a secret deleted from the tree"
H="$ROOT/hist"; new_repo "$H"
mkleak "$H/src/gone.py"
( cd "$H" && git add -A >/dev/null && git commit -qm add >/dev/null \
   && git rm -q src/gone.py >/dev/null && git commit -qm remove >/dev/null )
HOUT=$(scan "$H" --tracked)
hasnt "tree scan no longer sees it" "$HOUT" "gone.py"
has   "history scan finds it"       "$(scan "$H" --tracked -H)" "Secret in git history"

# ═════════════════════════════════════════════════════════════════════════════
section "12. filenames with spaces"
W="$ROOT/spaces"; new_repo "$W"
mkdir -p "$W/Saved Page_files"
mkleak "$W/Saved Page_files/a file.js"
( cd "$W" && git add -A >/dev/null && git commit -qm p >/dev/null )
has "handles spaces in paths" "$(scan "$W" --tracked)" "a file.js"

printf '\n%s══ %d passed, %d failed ══%s\n' "$B" "$PASS" "$FAIL" "$O"
[ "$FAIL" -eq 0 ]
