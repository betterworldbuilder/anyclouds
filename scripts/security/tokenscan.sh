#!/usr/bin/env bash
#
# tokenscan.sh — scan the repository for hardcoded tokens, credentials and
#                credential-bearing files.
#
# Usage:  scripts/security/tokenscan.sh [options]
#         scripts/security/tokenscan.sh --help
#
# Exit codes:  0 = clean   1 = findings   2 = usage/environment error
#
# Design notes (learned the hard way):
#   * `git grep` and ripgrep honour .gitignore, which hides *tracked* files such
#     as *.bak_*. The default mode walks the filesystem so nothing is hidden.
#   * Matches are printed with `grep -o` and redacted. A scanner must never dump
#     a secret (or a 2 MB minified line) into a CI log.
#   * The script never flags itself or its allowlist.
#
set -uo pipefail

VERSION="1.0.0"

# ─── locate repo root ─────────────────────────────────────────────────────────
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || {
        echo "tokenscan: cannot determine repository root" >&2; exit 2; }
fi
cd "$REPO_ROOT" || exit 2

SELF_REL="scripts/security/tokenscan.sh"

# ─── allowlist: reviewed false positives, embedded so this stays one file ──────
# POSIX ERE, matched against "path:lineno:match:context".
# Alternative for a one-off: put the marker  tokenscan:allow  on the source line.
ALLOW_PATTERNS=$(cat <<'PATTERNS'
# fetch()/XHR option, not a credential:  credentials: 'same-origin'
:.*credentials["']?[[:space:]]*[:=][[:space:]]*["'](same-origin|include|omit)["']
# CSS colour values:  secret_candidate:'#fee2e2,#dc2626'
:.*["']#[0-9a-fA-F]{6}
# printf/format templates:  "secret": "%s-secrets" % comp
:.*%[sd]
# variable holds a FILE PATH:  origin_vm_password_remote_path = "/tmp/..."
:.*_(path|file|dir|filename|remote_path)["']?[[:space:]]*[:=][[:space:]]*["'][./~]
# DOM id / localStorage KEY-NAME maps — the value is an element id, not a secret
:[[:space:]]*[A-Za-z_]+["']?:[[:space:]]*["'](cred|mig)[A-Za-z0-9_]*["'],?
:[[:space:]]*[A-Za-z_]+["']?:[[:space:]]*["'][a-z0-9]+(-[a-z0-9]+)+["'],?
# UI strings built by concatenation:  'Pull secret: '+(d.pull_secret||'')
:.*: ?["'][[:space:]]*\+[[:space:]]*\(
# empty defaults left by the 94b8750 credential purge
:.*:[[:space:]]*''[,]?[[:space:]]*$
# documented placeholders, not values
:.*placeholder=
:.*([Cc][Hh][Aa][Nn][Gg][Ee]_?[Mm][Ee]|REPLACE_?ME|TODO|FIXME|xxxx+|\.\.\.)
:.*["'][Pp]laceholder["']
:.*(e\.g\.|example\.com|your[-_ ]?(password|token|key|api)|<your|<password>|YOUR_)
^[^:]*\.(example|sample|template|dist)\.[^:]*:
# third-party / vendored code, full of doc examples like https://user:pw@host
:?.*(site-packages|node_modules|/venv/|/\.venv/|/vendor/)/
# secret-detection and redaction code: patterns, not secrets
^workflow_dashboard/ai_adoption/scanner\.py:
^workflow_dashboard/ai_adoption/importers\.py:
^services/ui/lib/uat_runner\.py:
^scripts/security/
# an OAuth *endpoint URL* constant that happens to be named GITHUB_TOKEN
^workflow_dashboard/ai_adoption/auth\.py:.*https://github\.com/login/oauth/access_token
# test fixtures with deliberately fake material (listed individually, so a real
# key committed to a new test file is still reported)
^tests/test_ai_adoption\.py:
^tests/test_monitoring_backend\.py:
^tests/test_r6_scan_appraisal\.py:
^tests/test_r6_generate_bundle\.py:
# saved copy of the Rackspace portal: 32-hex values are Chrome autofill debug
# metadata; main.js.download embeds a PEM marker inside a localised UI string
^The Rackspace Cloud_files/
# runtime OpenRC writers: f"export OS_PASSWORD={shlex.quote(pw)}" holds no value
:.*export OS_[A-Z_]+=[\{\$]
:.*(shlex|_shlex[0-9]?|_sx)\.quote
# deliberate demo credentials in throwaway POC apps (self-documented as demo)
^mockbank-e2e/.*:.*mockbank-demo-pw
^banking_poc/.*:.*DemoPass123
# docs describing the variables rather than setting them
^README\.md:
^docs/
PATTERNS
)

# ─── options ──────────────────────────────────────────────────────────────────
MODE="all"          # all | tracked | staged
SCAN_HISTORY=0
QUIET=0
VERBOSE=0
USE_ALLOW=1
USE_COLOR=auto

usage() {
    cat <<EOF
tokenscan.sh v$VERSION — find hardcoded tokens and credentials in this repo.

Usage: $SELF_REL [options]

Scan scope:
  -a, --all        Walk the filesystem, including .gitignore'd files (default).
                   Skips vendor dirs: .git node_modules .venv __pycache__
                   .pytest_cache include
  -t, --tracked    Only git-tracked files (fast; what a clone would publish).
  -s, --staged     Only staged files — for a pre-commit hook.
  -H, --history    ALSO scan every blob in git history (slow; finds secrets
                   that were committed and later removed). NOTE: applies only
                   the HIGH rules — a MEDIUM-shaped secret (e.g. a 32-hex API
                   key assigned to a variable) will NOT be found this way.
                   For those, use: git log -S'<the value>' --all

Output:
  -q, --quiet      Findings and summary only.
  -v, --verbose    Also list allowlisted suppressions and scan stats.
      --no-allow   Ignore the built-in allowlist (raw, unfiltered hits).
      --no-color   Disable ANSI colour.
  -h, --help       This text.

Exit codes: 0 clean, 1 findings, 2 usage/environment error.

Allowlist: edit the ALLOW_PATTERNS block near the top of this script (POSIX ERE,
matched against "path:line:match:context"), or put the marker  tokenscan:allow
on the offending source line.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--all)      MODE="all" ;;
        -t|--tracked)  MODE="tracked" ;;
        -s|--staged)   MODE="staged" ;;
        -H|--history)  SCAN_HISTORY=1 ;;
        -q|--quiet)    QUIET=1 ;;
        -v|--verbose)  VERBOSE=1 ;;
        --no-allow)    USE_ALLOW=0 ;;
        --no-color)    USE_COLOR=never ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "tokenscan: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ─── colour ───────────────────────────────────────────────────────────────────
if [ "$USE_COLOR" = auto ] && [ -t 1 ]; then USE_COLOR=always; fi
if [ "$USE_COLOR" = always ]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
    C_CYA=$'\033[36m'; C_DIM=$'\033[2m';  C_BLD=$'\033[1m'; C_off=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_CYA=""; C_DIM=""; C_BLD=""; C_off=""
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tokenscan.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

FILELIST="$TMP/files.z"
HITS="$TMP/hits.txt"
SUPPRESSED="$TMP/suppressed.txt"
: > "$HITS"; : > "$SUPPRESSED"

# ─── rule table:  SEVERITY | NAME | ERE ───────────────────────────────────────
# HIGH   = a real secret's distinctive shape; treat any hit as a live leak.
# MEDIUM = credential-shaped assignment; needs a human glance.
RULES=(
"HIGH|GitHub personal access token|github_pat_[A-Za-z0-9_]{22,}"
"HIGH|GitHub token (classic/oauth)|gh[pousr]_[A-Za-z0-9]{36,}"
"HIGH|Anthropic API key|sk-ant-[A-Za-z0-9_-]{20,}"
"HIGH|OpenAI API key|sk-(proj-)?[A-Za-z0-9_-]{32,}"
"HIGH|Slack token|xox[abposr]-[0-9A-Za-z-]{10,}"
"HIGH|Slack webhook|https://hooks\.slack\.com/services/[A-Za-z0-9/+_-]{20,}"
"HIGH|AWS access key id|(AKIA|ASIA)[0-9A-Z]{16}"
"HIGH|Google API key|AIza[0-9A-Za-z_-]{35}"
"HIGH|Google OAuth token|ya29\.[0-9A-Za-z_-]{30,}"
"HIGH|GitLab PAT|glpat-[0-9A-Za-z_-]{20}"
"HIGH|HuggingFace token|hf_[A-Za-z0-9]{34}"
"HIGH|DigitalOcean PAT|dop_v1_[a-f0-9]{64}"
"HIGH|SendGrid API key|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"
"HIGH|npm token|npm_[A-Za-z0-9]{36}"
"HIGH|PyPI token|pypi-[A-Za-z0-9_-]{50,}"
"HIGH|Stripe live key|(sk|rk)_live_[A-Za-z0-9]{20,}"
"HIGH|Twilio API key|SK[a-f0-9]{32}"
"HIGH|Shopify token|shp(at|ss|ca|pa)_[a-fA-F0-9]{32}"
"HIGH|Private key block|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----"
"HIGH|JWT|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}"
"HIGH|URL with inline credentials|(https?|postgres(ql)?|mysql|mongodb(\+srv)?|amqp|redis|ftp)://[A-Za-z0-9_.~-]+:[^/@[:space:]\"'\$\{]{6,}@"
"MEDIUM|OpenStack secret exported as literal|(export[[:space:]]+)?OS_(PASSWORD|API_KEY|TOKEN|APPLICATION_CREDENTIAL_SECRET)[[:space:]]*=[[:space:]]*[^\"'\$\{[:space:]#][^[:space:]#]{5,}"
"MEDIUM|32-hex value assigned to a secret name|(api_?key|apikey|token|password|passwd|secret)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[0-9a-fA-F]{32}([^0-9a-fA-F]|\$)"
"MEDIUM|Literal credential assignment|(password|passwd|api_?key|apikey|secret|token|credential)[a-z_]*[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'\$\{\}<>[:space:]]{10,}[\"']"
"MEDIUM|Hardcoded Authorization header|[Aa]uthorization[\"']?[[:space:]]*[:=][[:space:]]*[\"']?(Bearer|Basic)[[:space:]]+[A-Za-z0-9+/=_.-]{16,}"
"MEDIUM|Rackspace/OpenStack apikey field|(rackspace|ospc|flex)_?(api)?_?key[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'\$\{[:space:]]{16,}[\"']"
)

# Filenames that carry credentials by nature.
CRED_FILE_RE='(^|/)(\.env|\.env\..+|.+\.pem|.+\.key|.+\.p12|.+\.pfx|.+\.jks|.+\.keystore|credentials|\.npmrc|\.pypirc|\.htpasswd|id_(rsa|dsa|ecdsa|ed25519)|.*openrc.*|clouds\.ya?ml|secrets?\.(ya?ml|json)|kubeconfig)$'

PRUNE_DIRS=(.git node_modules .venv venv site-packages __pycache__ .pytest_cache
            .mypy_cache .ruff_cache .tox include)

# ─── build the file list ──────────────────────────────────────────────────────
build_filelist() {
    case "$MODE" in
        tracked) git ls-files -z > "$FILELIST" ;;
        staged)  git diff --cached -z --name-only --diff-filter=ACM > "$FILELIST" ;;
        all)
            local args=( . )
            for d in "${PRUNE_DIRS[@]}"; do
                args+=( -name "$d" -prune -o )
            done
            find "${args[@]}" -type f -print0 > "$FILELIST" 2>/dev/null
            ;;
    esac
    # staged/tracked modes can name deleted files; keep only what exists
    if [ "$MODE" != all ]; then
        local keep="$TMP/keep.z"; : > "$keep"
        while IFS= read -r -d '' f; do
            [ -f "$f" ] && printf '%s\0' "$f" >> "$keep"
        done < "$FILELIST"
        mv "$keep" "$FILELIST"
    fi
}

file_count() { tr -dc '\0' < "$FILELIST" | wc -c | tr -d ' '; }

# ─── helpers ──────────────────────────────────────────────────────────────────
# Show enough of a match to identify it, never enough to use it.
# NB: `local s="$1" n=${#s}` does NOT work — bash expands every word on the
# line before performing any assignment, so ${#s} would read the old s.
redact() {
    local s="$1"
    local n=${#s}
    if   [ "$n" -le 8 ];  then printf '%s' "[redacted]"
    elif [ "$n" -le 20 ]; then printf '%.4s…[%d chars]' "$s" "$n"
    else printf '%.6s…%s [%d chars]' "$s" "${s: -2}" "$n"
    fi
}

allow_regexes() {
    [ "$USE_ALLOW" -eq 1 ] || return 0
    printf '%s\n' "$ALLOW_PATTERNS" | grep -vE '^[[:space:]]*(#|$)'
}

is_allowed() { # is_allowed <record>
    local rec="$1" re
    while IFS= read -r re; do
        [ -n "$re" ] || continue
        printf '%s' "$rec" | grep -qE -- "$re" && return 0
    done <<< "$ALLOW_CACHE"
    return 1
}

# ─── the scan ─────────────────────────────────────────────────────────────────
declare -A SEEN=()

scan_content() {
    local sev name re rule
    for rule in "${RULES[@]}"; do
        sev=${rule%%|*}
        name=${rule#*|}; name=${name%%|*}
        re=${rule#*|}; re=${re#*|}

        # -o keeps output tiny even inside minified bundles; -I skips binaries.
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            local path lineno match
            path=${line%%:*};              local rest=${line#*:}
            lineno=${rest%%:*};            match=${rest#*:}

            # Normalise ./foo -> foo so allowlist anchors work in every mode
            # (find emits ./foo, git ls-files emits foo).
            path=${path#./}

            # never flag the scanner or its allowlist
            case "$path" in
                "$SELF_REL") continue ;;
            esac

            # one report per file:line:rule, however many times it matches
            # (a single minified line can match the same rule dozens of times)
            local key="$path|$lineno|$name"
            [ -n "${SEEN[$key]+x}" ] && continue
            SEEN[$key]=1

            # pull the source line for context-based allowlisting (truncated)
            local ctx=""
            if [ -r "$path" ]; then
                ctx=$(sed -n "${lineno}p" "$path" 2>/dev/null | tr -d '\0' | cut -c1-160)
            fi
            case "$ctx" in *tokenscan:allow*) continue ;; esac

            local rec="$path:$lineno:$match:$ctx"
            if is_allowed "$rec"; then
                printf '%s\t%s\t%s\t%s\n' "$sev" "$name" "$path:$lineno" "$(redact "$match")" >> "$SUPPRESSED"
            else
                printf '%s\t%s\t%s\t%s\n' "$sev" "$name" "$path:$lineno" "$(redact "$match")" >> "$HITS"
            fi
        done < <(xargs -0 -r grep -nIHoE -- "$re" < "$FILELIST" 2>/dev/null)
    done
}

scan_cred_files() {
    local f rec
    while IFS= read -r -d '' f; do
        local rel=${f#./}
        printf '%s' "$rel" | grep -qE -- "$CRED_FILE_RE" || continue
        case "$rel" in "$SELF_REL") continue ;; esac

        local tracked=no
        git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && tracked=yes

        rec="$rel:0:credential-file:$rel"
        if is_allowed "$rec"; then
            printf 'INFO\tCredential file (allowlisted)\t%s\t%s\n' "$rel" "tracked=$tracked" >> "$SUPPRESSED"
        elif [ "$tracked" = yes ]; then
            printf 'HIGH\tCredential file COMMITTED to git\t%s\t%s\n' "$rel" "remove and rotate" >> "$HITS"
        else
            printf 'INFO\tCredential file present but untracked\t%s\t%s\n' "$rel" "keep it gitignored" >> "$HITS"
        fi
    done < "$FILELIST"
}

scan_history() {
    [ "$SCAN_HISTORY" -eq 1 ] || return 0
    [ "$QUIET" -eq 1 ] || echo "${C_DIM}scanning git history (this can take a while)…${C_off}"

    local combined="" rule re
    for rule in "${RULES[@]}"; do
        [ "${rule%%|*}" = HIGH ] || continue
        re=${rule#*|}; re=${re#*|}
        combined="${combined:+$combined|}(${re})"
    done

    local n=0
    while IFS= read -r sha; do
        if git cat-file blob "$sha" 2>/dev/null | grep -qIE -- "$combined"; then
            local where
            where=$(git rev-list --objects --all 2>/dev/null | awk -v s="$sha" '$1==s {print $2; exit}')
            where=${where:-<blob>}

            # honour the allowlist here too — otherwise every historical copy of
            # a test fixture or vendored dependency is reported as a leak
            if is_allowed "$where:0:history:$where"; then
                printf 'HIGH\tSecret in git history (allowlisted path)\t%s\t%s\n' \
                    "$where" "suppressed" >> "$SUPPRESSED"
                continue
            fi

            printf 'HIGH\tSecret in git history\t%s\t%s\n' "$where ($(echo "$sha" | cut -c1-8))" "rotate; history rewrite required" >> "$HITS"
            n=$((n+1))
            [ "$n" -ge 40 ] && { echo "  … stopping after 40 history hits" >&2; break; }
        fi
    done < <(git rev-list --objects --all 2>/dev/null | awk 'NF==2 {print $1}' | sort -u)
}

# ─── report ───────────────────────────────────────────────────────────────────
report() {
    local nhigh nmed ninfo nsup
    nhigh=$(grep -c '^HIGH'   "$HITS" 2>/dev/null || true);  nhigh=${nhigh:-0}
    nmed=$(grep -c '^MEDIUM'  "$HITS" 2>/dev/null || true);  nmed=${nmed:-0}
    ninfo=$(grep -c '^INFO'   "$HITS" 2>/dev/null || true);  ninfo=${ninfo:-0}
    nsup=$(grep -c . "$SUPPRESSED" 2>/dev/null || true);     nsup=${nsup:-0}

    print_group() { # print_group <SEV> <colour> <heading>
        local sev="$1" col="$2" head="$3"
        grep "^$sev" "$HITS" >/dev/null 2>&1 || return 0
        echo
        echo "${col}${C_BLD}${head}${C_off}"
        awk -F'\t' -v c="$col" -v o="$C_off" -v d="$C_DIM" \
            '{printf "  %s%-44s%s %s\n      %s%s%s\n", c, $3, o, $2, d, $4, o}' \
            <(grep "^$sev" "$HITS")
    }

    print_group HIGH   "$C_RED" "HIGH — treat as a live leak, rotate immediately"
    print_group MEDIUM "$C_YEL" "MEDIUM — credential-shaped, needs review"
    print_group INFO   "$C_CYA" "INFO"

    if [ "$VERBOSE" -eq 1 ] && [ "$nsup" -gt 0 ]; then
        echo
        echo "${C_DIM}${C_BLD}Allowlisted (${nsup}) — reviewed, not secrets${C_off}"
        awk -F'\t' -v d="$C_DIM" -v o="$C_off" \
            '{printf "  %s%-44s %s%s\n", d, $3, $2, o}' "$SUPPRESSED"
    fi

    echo
    if [ $((nhigh + nmed)) -eq 0 ]; then
        echo "${C_GRN}${C_BLD}✅ CLEAN${C_off} — no hardcoded tokens or credentials found."
        [ "$ninfo" -gt 0 ] && echo "   ${ninfo} informational item(s) above."
        [ "$nsup" -gt 0 ] && echo "   ${nsup} known-benign match(es) suppressed by the allowlist (-v to list)."
    else
        echo "${C_RED}${C_BLD}❌ ${nhigh} high, ${nmed} medium finding(s).${C_off}"
        echo "   False positive? Add a pattern to ALLOW_PATTERNS in this script"
        echo "   or put  tokenscan:allow  on the offending line."
    fi

    if [ "$VERBOSE" -eq 1 ] || [ "$QUIET" -eq 0 ]; then
        echo "${C_DIM}   scope=$MODE files=$(file_count) rules=${#RULES[@]}$([ "$SCAN_HISTORY" -eq 1 ] && echo " +history")${C_off}"
    fi

    [ $((nhigh + nmed)) -eq 0 ] && return 0 || return 1
}

# ─── main ─────────────────────────────────────────────────────────────────────
ALLOW_CACHE=$(allow_regexes)

[ "$QUIET" -eq 1 ] || echo "${C_BLD}tokenscan v$VERSION${C_off} — $REPO_ROOT"

build_filelist
if [ "$(file_count)" -eq 0 ]; then
    echo "tokenscan: no files to scan (scope=$MODE)" >&2
    exit 0
fi

scan_content
scan_cred_files
scan_history
report
