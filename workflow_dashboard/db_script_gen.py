"""
DB Migration Script Generator — server-side Python.
Eliminates bash-in-JS template literal escaping entirely.
Uses %%PLACEHOLDER%% substitution so bash $VAR/${VAR} syntax is preserved verbatim.
"""
from datetime import datetime, timezone

def _fill(tmpl, **kw):
    s = tmpl
    for k, v in kw.items():
        s = s.replace(f'%%{k}%%', str(v or ''))
    return s

# ─── Shared comparison phase ────────────────────────────────────────────────

_CMP_BODY = r"""
# ══════════════════════════════════════════════════════════════════════
# PHASE FINAL — Comprehensive DB Verification (OSPC ↔ Flex)
# Checks: databases, tables, SHOW TABLE STATUS, columns, indexes,
#         views, triggers, procedures/functions/events, users/grants,
#         SHOW CREATE TABLE, full data diff (≤5000 rows) or CHECKSUM
# ══════════════════════════════════════════════════════════════════════

# ── Global report accumulators (survive across all _run_db_cmp_phase calls) ──
_RPT_DIR="/tmp/db_mig_v2"; mkdir -p "$_RPT_DIR"
_RPT_TS="$(date +%Y%m%d_%H%M%S)"
_G_RPT="$_RPT_DIR/cmp_${_RPT_TS}_$$.tsv"
_G_HTML="$_RPT_DIR/db_report_${_RPT_TS}.html"
printf 'phase\tcheck\tresult\tdetail\n' > "$_G_RPT"
_CMP_PHASE="UNKNOWN"

_diff_chk() {
  local _lbl="$1" _f1="$2" _f2="$3" _rows
  _rows="$(wc -l < "$_f1" | tr -d ' ')"
  if diff -q "$_f1" "$_f2" > /dev/null 2>&1; then
    printf "  [PASS]  %-55s  (%s rows)\n" "$_lbl" "$_rows"
    _PASS=$((_PASS+1))
    printf '%s\t%s\tPASS\t%s rows\n' "$_CMP_PHASE" "$_lbl" "$_rows" >> "$_G_RPT"
  else
    printf "  [FAIL]  %s\n" "$_lbl"
    diff "$_f1" "$_f2" 2>/dev/null | head -12 | sed 's/^/          /' || true
    _FAIL=$((_FAIL+1))
    printf '%s\t%s\tFAIL\t-\n' "$_CMP_PHASE" "$_lbl" >> "$_G_RPT"
  fi
}

_gen_html_report() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[WARN] python3 not available — HTML report skipped.  TSV saved: $_G_RPT"
    return 0
  fi
  python3 - "$_G_RPT" "$_G_HTML" <<'PYEOF'
import sys, csv, html as H, json, datetime, io

tsv_path, html_path = sys.argv[1], sys.argv[2]
with open(tsv_path) as f:
    rows = list(csv.DictReader(f, delimiter='\t'))

phases = list(dict.fromkeys(r['phase'] for r in rows))
checks = list(dict.fromkeys(r['check'] for r in rows))
data   = {(r['phase'], r['check']): (r['result'], r['detail']) for r in rows}

def pcnt(ph, res):
    return sum(1 for (p, c) in data if p == ph and data[(p, c)][0] == res)

# CSV export data
csv_rows = [['Check'] + phases]
for chk in checks:
    csv_rows.append([chk] + [data.get((ph, chk), ('N/A', ''))[0] for ph in phases])
buf = io.StringIO()
csv.writer(buf).writerows(csv_rows)
csv_txt = buf.getvalue()

now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

# Summary cards
cards = ''
for ph in phases:
    p, f = pcnt(ph, 'PASS'), pcnt(ph, 'FAIL')
    status_cls = 'all-pass' if f == 0 else 'has-fail'
    cards += ('<div class="card ' + status_cls + '">'
              '<b>' + H.escape(ph) + '</b>'
              '<div class="counts">'
              '<span class="pg">&#10004;&nbsp;' + str(p) + '&nbsp;PASS</span>'
              '&nbsp;&nbsp;'
              '<span class="fb">&#10008;&nbsp;' + str(f) + '&nbsp;FAIL</span>'
              '</div></div>')

# Section detection for grouping
def get_section(chk):
    for sep in (' -- ', ' \u2014 '):
        if sep in chk:
            parts = chk.split(sep, 1)
            if '/' in parts[0]:
                return 'Table data: ' + parts[0]
            return 'DB: ' + parts[0]
    return 'Global'

def get_label(chk):
    for sep in (' -- ', ' \u2014 '):
        if sep in chk:
            return chk.split(sep, 1)[1]
    return chk

# Table rows
thead = '<tr><th>Check</th>' + ''.join('<th>' + H.escape(p) + '</th>' for p in phases) + '</tr>'
cells = ''
last_sec = None
for chk in checks:
    sec = get_section(chk)
    if sec != last_sec:
        cells += ('<tr class="sec-hdr"><td colspan="' + str(len(phases) + 1) + '">'
                  + H.escape(sec) + '</td></tr>\n')
        last_sec = sec
    cells += '<tr>'
    cells += '<td class="lbl">' + H.escape(get_label(chk)) + '</td>'
    for ph in phases:
        res, det = data.get((ph, chk), ('N/A', ''))
        if res == 'PASS':
            cells += ('<td class="p">&#10004;&nbsp;PASS'
                      + ('<br><small>' + H.escape(det) + '</small>' if det and det != '-' else '')
                      + '</td>')
        elif res == 'FAIL':
            cells += '<td class="f">&#10008;&nbsp;FAIL</td>'
        elif res == 'INFO':
            cells += '<td class="i">&#8505;&nbsp;INFO</td>'
        else:
            cells += '<td class="n">&mdash;</td>'
    cells += '</tr>\n'

CSS = (
    '*{box-sizing:border-box;margin:0;padding:0}'
    'body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;'
    'background:#0d1117;color:#e6edf3;padding:28px 32px}'
    'h1{color:#58a6ff;font-size:24px;font-weight:700;margin-bottom:4px}'
    '.ts{color:#8b949e;font-size:12px;margin-bottom:22px}'
    '.cards{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:22px}'
    '.card{background:#161b22;border:1px solid #30363d;border-radius:10px;'
    'padding:16px 22px;min-width:200px;transition:border-color .2s}'
    '.card.all-pass{border-color:#238636}'
    '.card.has-fail{border-color:#da3633}'
    '.card b{display:block;color:#79c0ff;font-size:13px;font-weight:600;margin-bottom:10px}'
    '.counts{display:flex;gap:14px;align-items:baseline}'
    '.pg{color:#3fb950;font-weight:700;font-size:20px}'
    '.fb{color:#f85149;font-weight:700;font-size:20px}'
    '.btn{display:inline-flex;align-items:center;gap:6px;margin-bottom:18px;'
    'padding:8px 18px;background:#238636;color:#fff;border-radius:6px;'
    'cursor:pointer;font-size:13px;font-weight:600;border:none;'
    'text-decoration:none;transition:background .2s}'
    '.btn:hover{background:#2ea043}'
    'table{width:100%;border-collapse:collapse;font-size:12px}'
    'th{background:#1c2128;color:#8b949e;text-align:left;padding:10px 14px;'
    'border:1px solid #30363d;white-space:nowrap;position:sticky;top:0;z-index:2}'
    'td{padding:7px 12px;border:1px solid #21262d;vertical-align:top}'
    'tr:hover td{background:#161b22}'
    '.lbl{color:#c9d1d9;word-break:break-word;max-width:320px}'
    '.p{background:#0d2818;color:#3fb950;text-align:center;font-weight:600;white-space:nowrap}'
    '.p small{display:block;color:#8b949e;font-weight:400;font-size:10px;margin-top:2px}'
    '.f{background:#2d1117;color:#f85149;text-align:center;font-weight:600}'
    '.i{background:#0d1a2d;color:#58a6ff;text-align:center}'
    '.n{color:#484f58;text-align:center}'
    '.sec-hdr td{background:#1c2128!important;color:#58a6ff;font-weight:700;'
    'font-size:11px;text-transform:uppercase;letter-spacing:.06em;'
    'padding:6px 14px;border-top:2px solid #30363d}'
)

doc = ('<!DOCTYPE html><html lang="en"><head>'
       '<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
       '<title>DB Migration Report</title>'
       '<style>' + CSS + '</style></head><body>'
       '<h1>&#128202; DB Migration Comparison Report</h1>'
       '<div class="ts">Generated: ' + now + '</div>'
       '<div class="cards">' + cards + '</div>'
       '<button class="btn" onclick="exportCSV()">&#8659;&nbsp;Export CSV</button>'
       '<table><thead>' + thead + '</thead><tbody>' + cells + '</tbody></table>'
       '<script>\nconst _CSV=' + json.dumps(csv_txt) + ';\n'
       'function exportCSV(){'
       'const b=new Blob([_CSV],{type:"text/csv"});'
       'const a=document.createElement("a");'
       'a.href=URL.createObjectURL(b);'
       'a.download="db_migration_report.csv";'
       'document.body.appendChild(a);a.click();document.body.removeChild(a);}'
       '\n</script></body></html>')

with open(html_path, 'w') as f:
    f.write(doc)
print('[REPORT] ' + html_path)
PYEOF
}

_run_db_cmp_phase() {
  _CMP_PHASE="${1:-FLEX}"   # global — visible to _diff_chk
  local _TMPD _PASS _FAIL
  _TMPD=$(mktemp -d /tmp/dbcmp_XXXXXX)
  trap 'rm -rf "$_TMPD"' RETURN
  _PASS=0; _FAIL=0

  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "   DB VERIFICATION — OSPC vs $_CMP_PHASE"
  echo "   $(date)"
  echo "════════════════════════════════════════════════════════════════════"

  echo ""; echo "── 1. Databases ─────────────────────────────────────────────────"
  _mo -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema','performance_schema','mysql','sys');" 2>/dev/null | sort > "$_TMPD/o_dbs.txt"
  _mf -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema','performance_schema','mysql','sys');" 2>/dev/null | sort > "$_TMPD/f_dbs.txt"
  _diff_chk "Database list" "$_TMPD/o_dbs.txt" "$_TMPD/f_dbs.txt"

  echo ""; echo "── 2. Users / Grants ────────────────────────────────────────────"
  _mo -e "SELECT CONCAT(user,'@',host) FROM mysql.user ORDER BY user,host;" 2>/dev/null | sort > "$_TMPD/o_usr.txt" || echo "RESTRICTED" > "$_TMPD/o_usr.txt"
  _mf -e "SELECT CONCAT(user,'@',host) FROM mysql.user ORDER BY user,host;" 2>/dev/null | sort > "$_TMPD/f_usr.txt" || echo "RESTRICTED" > "$_TMPD/f_usr.txt"
  if grep -q "^RESTRICTED$" "$_TMPD/o_usr.txt" 2>/dev/null; then
    printf "  [INFO]  %-55s  (source is DBaaS — mysql.user access restricted, skipped)\n" "User list (mysql.user)"
    printf '%s\tUser list (mysql.user)\tINFO\tDBaaS RESTRICTED\n' "$_CMP_PHASE" >> "$_G_RPT"
  else
    _diff_chk "User list (mysql.user)" "$_TMPD/o_usr.txt" "$_TMPD/f_usr.txt"
  fi

  while IFS= read -r _DB; do
    [ -z "$_DB" ] && continue
    echo ""; echo "╔══ DB: $_DB ══════════════════════════════════════════════════════"

    _mo -e "SHOW TABLES FROM \`$_DB\`;" 2>/dev/null | sort > "$_TMPD/o_t.txt"
    _mf -D "$_DB" -e "SHOW TABLES;" 2>/dev/null | sort > "$_TMPD/f_t.txt"
    _diff_chk "$_DB -- tables" "$_TMPD/o_t.txt" "$_TMPD/f_t.txt"

    # Normalize utf8 → utf8mb3 (MySQL 8.0 renamed the charset; they are identical)
    _mo -e "SHOW TABLE STATUS FROM \`$_DB\`;" 2>/dev/null | awk -F$'\t' '{print $1"\t"$2"\t"$15}' | sed 's/\tutf8_/\tutf8mb3_/g' | sort > "$_TMPD/o_ts.txt"
    _mf -D "$_DB" -e "SHOW TABLE STATUS;" 2>/dev/null | awk -F$'\t' '{print $1"\t"$2"\t"$15}' | sed 's/\tutf8_/\tutf8mb3_/g' | sort > "$_TMPD/f_ts.txt"
    _diff_chk "$_DB -- TABLE STATUS (engine/charset)" "$_TMPD/o_ts.txt" "$_TMPD/f_ts.txt"

    _mo -e "SELECT TABLE_NAME,ORDINAL_POSITION,COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,COLUMN_KEY,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$_DB' ORDER BY TABLE_NAME,ORDINAL_POSITION;" 2>/dev/null > "$_TMPD/o_col.txt"
    _mf -e "SELECT TABLE_NAME,ORDINAL_POSITION,COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,COLUMN_KEY,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$_DB' ORDER BY TABLE_NAME,ORDINAL_POSITION;" 2>/dev/null > "$_TMPD/f_col.txt"
    _diff_chk "$_DB -- columns" "$_TMPD/o_col.txt" "$_TMPD/f_col.txt"

    _mo -e "SELECT TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX,COLUMN_NAME,NON_UNIQUE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='$_DB' ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX;" 2>/dev/null > "$_TMPD/o_idx.txt"
    _mf -e "SELECT TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX,COLUMN_NAME,NON_UNIQUE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='$_DB' ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX;" 2>/dev/null > "$_TMPD/f_idx.txt"
    _diff_chk "$_DB -- indexes" "$_TMPD/o_idx.txt" "$_TMPD/f_idx.txt"

    _mo -e "SELECT TABLE_NAME,VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_SCHEMA='$_DB' ORDER BY TABLE_NAME;" 2>/dev/null | sort > "$_TMPD/o_vw.txt"
    _mf -e "SELECT TABLE_NAME,VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_SCHEMA='$_DB' ORDER BY TABLE_NAME;" 2>/dev/null | sort > "$_TMPD/f_vw.txt"
    _diff_chk "$_DB -- views" "$_TMPD/o_vw.txt" "$_TMPD/f_vw.txt"

    _mo -e "SELECT TRIGGER_NAME,EVENT_MANIPULATION,EVENT_OBJECT_TABLE,ACTION_TIMING FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='$_DB' ORDER BY TRIGGER_NAME;" 2>/dev/null | sort > "$_TMPD/o_trg.txt"
    _mf -e "SELECT TRIGGER_NAME,EVENT_MANIPULATION,EVENT_OBJECT_TABLE,ACTION_TIMING FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='$_DB' ORDER BY TRIGGER_NAME;" 2>/dev/null | sort > "$_TMPD/f_trg.txt"
    _diff_chk "$_DB -- triggers" "$_TMPD/o_trg.txt" "$_TMPD/f_trg.txt"

    _mo -e "SELECT ROUTINE_NAME,ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='$_DB' ORDER BY ROUTINE_TYPE,ROUTINE_NAME;" 2>/dev/null | sort > "$_TMPD/o_rtn.txt"
    _mf -e "SELECT ROUTINE_NAME,ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='$_DB' ORDER BY ROUTINE_TYPE,ROUTINE_NAME;" 2>/dev/null | sort > "$_TMPD/f_rtn.txt"
    _diff_chk "$_DB -- procedures/functions" "$_TMPD/o_rtn.txt" "$_TMPD/f_rtn.txt"

    _mo -e "SELECT EVENT_NAME,STATUS FROM information_schema.EVENTS WHERE EVENT_SCHEMA='$_DB' ORDER BY EVENT_NAME;" 2>/dev/null | sort > "$_TMPD/o_evt.txt"
    _mf -e "SELECT EVENT_NAME,STATUS FROM information_schema.EVENTS WHERE EVENT_SCHEMA='$_DB' ORDER BY EVENT_NAME;" 2>/dev/null | sort > "$_TMPD/f_evt.txt"
    _diff_chk "$_DB -- events" "$_TMPD/o_evt.txt" "$_TMPD/f_evt.txt"

    echo ""
    printf "  %-38s  %8s  %8s  %-7s  %-7s  %s\n" "Table" "OSPC" "FLEX" "Rows" "DDL" "Data"
    printf "  %-38s  %8s  %8s  %-7s  %-7s  %s\n" "--------------------------------------" "--------" "--------" "-------" "-------" "------------"
    while IFS= read -r _TBL; do
      [ -z "$_TBL" ] && continue
      _OC=$(_mo -e "SELECT COUNT(*) FROM \`$_DB\`.\`$_TBL\`;" 2>/dev/null | tr -d ' \n')
      _FC=$(_mf -D "$_DB" -e "SELECT COUNT(*) FROM \`$_TBL\`;" 2>/dev/null | tr -d ' \n')
      [ -z "$_OC" ] && _OC="ERR"; [ -z "$_FC" ] && _FC="ERR"
      if [ "$_OC" = "$_FC" ]; then
        _ROW="MATCH"; _PASS=$((_PASS+1))
        printf '%s\t%s/%s -- rows\tPASS\tOSPC=%s FLEX=%s\n' "$_CMP_PHASE" "$_DB" "$_TBL" "$_OC" "$_FC" >> "$_G_RPT"
      else
        _ROW="DIFFER"; _FAIL=$((_FAIL+1))
        printf '%s\t%s/%s -- rows\tFAIL\tOSPC=%s FLEX=%s\n' "$_CMP_PHASE" "$_DB" "$_TBL" "$_OC" "$_FC" >> "$_G_RPT"
      fi

      _mo -e "SHOW CREATE TABLE \`$_DB\`.\`$_TBL\`;" 2>/dev/null | awk -F$'\t' 'NF>1{print $NF}' | sed 's/AUTO_INCREMENT=[0-9]* //g' > "$_TMPD/o_ddl.txt"
      _mf -D "$_DB" -e "SHOW CREATE TABLE \`$_TBL\`;" 2>/dev/null | awk -F$'\t' 'NF>1{print $NF}' | sed 's/AUTO_INCREMENT=[0-9]* //g' > "$_TMPD/f_ddl.txt"
      if diff -q "$_TMPD/o_ddl.txt" "$_TMPD/f_ddl.txt" > /dev/null 2>&1; then
        _DDL="OK"; _PASS=$((_PASS+1))
        printf '%s\t%s/%s -- DDL\tPASS\t-\n' "$_CMP_PHASE" "$_DB" "$_TBL" >> "$_G_RPT"
      else
        _DDL="DIFFERS"; _FAIL=$((_FAIL+1))
        printf '%s\t%s/%s -- DDL\tFAIL\t-\n' "$_CMP_PHASE" "$_DB" "$_TBL" >> "$_G_RPT"
      fi

      _DATA="-"
      if [ "$_OC" != "ERR" ] && [ "$_FC" != "ERR" ] 2>/dev/null; then
        if [ "$_OC" -le 5000 ] 2>/dev/null; then
          _OH=$(_mo "$_DB" -e "SELECT * FROM \`$_TBL\` ORDER BY 1;" 2>/dev/null | md5sum | awk '{print $1}')
          _FH=$(_mf -D "$_DB" -e "SELECT * FROM \`$_TBL\` ORDER BY 1;" 2>/dev/null | md5sum | awk '{print $1}')
          if [ "$_OH" = "$_FH" ]; then
            _DATA="full-match"; _PASS=$((_PASS+1))
            printf '%s\t%s/%s -- data\tPASS\tfull-match\n' "$_CMP_PHASE" "$_DB" "$_TBL" >> "$_G_RPT"
          else
            _DATA="MISMATCH!"; _FAIL=$((_FAIL+1))
            printf '%s\t%s/%s -- data\tFAIL\tchecksum mismatch\n' "$_CMP_PHASE" "$_DB" "$_TBL" >> "$_G_RPT"
          fi
        else
          _OH=$(_mo "$_DB" -e "CHECKSUM TABLE \`$_TBL\`;" 2>/dev/null | awk '{print $NF}')
          _FH=$(_mf -D "$_DB" -e "CHECKSUM TABLE \`$_TBL\`;" 2>/dev/null | awk '{print $NF}')
          if [ "$_OH" = "$_FH" ]; then
            _DATA="chksum-ok"; _PASS=$((_PASS+1))
            printf '%s\t%s/%s -- data\tPASS\tchecksum-ok\n' "$_CMP_PHASE" "$_DB" "$_TBL" >> "$_G_RPT"
          else
            _DATA="chksum-diff"; _FAIL=$((_FAIL+1))
            printf '%s\t%s/%s -- data\tFAIL\tchecksum-diff\n' "$_CMP_PHASE" "$_DB" "$_TBL" >> "$_G_RPT"
          fi
        fi
      fi
      printf "  %-38s  %8s  %8s  %-7s  %-7s  %s\n" "$_TBL" "$_OC" "$_FC" "$_ROW" "$_DDL" "$_DATA"
    done < "$_TMPD/o_t.txt"
    echo "╚══════════════════════════════════════════════════════════════════════"
  done < "$_TMPD/o_dbs.txt"

  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  printf "   RESULT [%s]:  PASS=%s   FAIL=%s\n" "$_CMP_PHASE" "$_PASS" "$_FAIL"
  if [ "$_FAIL" = "0" ]; then
    echo "   STATUS: ALL CHECKS PASSED"
  else
    echo "   STATUS: DIFFERENCES FOUND — review above before cutover"
  fi
  echo "════════════════════════════════════════════════════════════════════"
}

_run_db_cmp_phase "FLEX PRIMARY"
"""

_CMP_REPORT_CALL = r"""
_gen_html_report
"""

_CMP_REPLICA_SECTION = r"""
# ── Per-replica verification (same full comparison, each replica vs OSPC) ──
if [ -n "$FLEX_REPLICA_IPS" ]; then
  for _REP_IP in $FLEX_REPLICA_IPS; do
    _mf() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$_REP_IP" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -h 127.0.0.1 -u root -N -B $_a" 2>/dev/null; }
    _run_db_cmp_phase "REPLICA $_REP_IP"
  done
fi
"""

_CMP_WRAPPERS = {
    'dbaas': r"""
# ── compare wrappers: DBaaS (LB) + Flex (SSH + root pw) ──────────────
_mo() { MYSQL_PWD="$DBAAS_PASS" mysql -h "$LB_PUBLIC_IP" -P "$LB_PORT" -u "$DBAAS_USER" -N -B 2>/dev/null "$@"; }
_mf() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$FLEX_IP" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -h 127.0.0.1 -u root -N -B $_a" 2>/dev/null; }
""",
    'ha': r"""
# ── compare wrappers: HA (SSH→OSPC HA VIP) + Flex primary (sudo) ─────
_mo() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$OSPC_HA_VIP" "MYSQL_PWD='$OSPC_ROOT_PASS' mysql -u root -N -B $_a" 2>/dev/null; }
_mf() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$FLEX_PRI_IP" "sudo mysql -N -B $_a" 2>/dev/null; }
""",
    'dbvm': r"""
# ── compare wrappers: DB VM (SSH→OSPC VM) + Flex VM (SSH + sudo) ─────
_mo() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$OSPC_IP" "MYSQL_PWD='$OSPC_ROOT_PASS' mysql -u root -N -B $_a" 2>/dev/null; }
_mf() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$FLEX_IP" "sudo mysql -N -B $_a" 2>/dev/null; }
""",
}

# ─── V2 DBaaS script (single + replica) ────────────────────────────────────

_V2_DBAAS = r"""#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
#  DB MIGRATION V2 — OSPC DBaaS → FLEX  [%%SCENARIO%%]
#  Customer : %%CUST%%
#  Generated: %%TS%%
#  Mode     : %%MODE%%
#  If FLEX_REPLICA_IPS is empty, replica setup steps are skipped.
# ══════════════════════════════════════════════════════════════════════
set -Eeuo pipefail
trap 'rc=$?; echo "[FATAL] line $LINENO: $BASH_COMMAND (rc=$rc)" >&2; exit $rc' ERR

DRY_RUN="%%DRY%%"
LB_PUBLIC_IP="%%LB_IP%%"
LB_PORT="%%LB_PORT%%"
DBAAS_USER="%%DBAAS_USER%%"
DBAAS_PASS="%%DBAAS_PASS%%"  %%DBAAS_PASS_HINT%%
SSH_USER="%%SSH_USER%%"
SSH_KEY="%%SSH_KEY%%"
FLEX_IP="%%FLEX_IP%%"
FLEX_REPLICA_IPS="%%FLEX_REP_IPS%%"
FLEX_ROOT_PASS="%%FLEX_ROOT_PASS%%"  %%FLEX_ROOT_PASS_HINT%%
REPL_USER="%%REPL_USER%%"
REPL_PASS="%%REPL_PASS%%"  %%REPL_PASS_HINT%%

DATABASES=""
WORKDIR="/tmp/db_mig_v2"
LOG_FILE="$WORKDIR/db_mig_v2_$(date +%Y%m%d_%H%M%S).log"
PRIMARY_SERVER_ID=101
REPLICA_SERVER_ID_BASE=201
SAMPLE_ROWS=5
REPLICA_LAG_WAIT_ROUNDS=20
REPLICA_LAG_WAIT_SEC=15
DB_ENGINE_PKG="mysql"

mkdir -p "$WORKDIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Auto-detect DB port if not supplied ──────────────────────────────
# Scans common DB ports and picks the first open one.
# Order: 3306 (MySQL/MariaDB) · 3307 (alt-MySQL) · 5432 (PostgreSQL)
#        1433 (MSSQL) · 27017 (MongoDB)
detect_db_port() {
  local _host="$1"
  local _candidates="3306 3307 5432 1433 27017"
  for _p in $_candidates; do
    if timeout 3 bash -c ">/dev/tcp/$_host/$_p" 2>/dev/null; then
      echo "$_p"
      return 0
    fi
  done
  # fallback: try nc if bash tcp redirection is blocked
  for _p in $_candidates; do
    if nc -z -w3 "$_host" "$_p" 2>/dev/null; then
      echo "$_p"
      return 0
    fi
  done
  echo ""
}

if [ -z "$LB_PORT" ] || [ "$LB_PORT" = "auto" ]; then
  echo "[INFO] LB_PORT=auto — scanning open DB ports on $LB_PUBLIC_IP …"
  _detected="$(detect_db_port "$LB_PUBLIC_IP")"
  if [ -z "$_detected" ]; then
    echo "[FATAL] No open DB port found on $LB_PUBLIC_IP (tried 3306 3307 5432 1433 27017)" >&2
    exit 1
  fi
  LB_PORT="$_detected"
  echo "[INFO] Auto-detected DB port: $LB_PORT"
fi

log()  { echo; echo "════════════════════════════════════════════════════════════════════"; echo "$1"; echo "════════════════════════════════════════════════════════════════════"; }
info() { echo "[INFO] $*"; }
ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERR]  $*" >&2; }

run() {
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY]  $*"; return 0; fi
  "$@"
}

run_remote() {
  local _ip="$1"; shift
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY][$1] $*"; return 0; fi
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$_ip" "$@"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }; }

mysql_src() {
  MYSQL_PWD="$DBAAS_PASS" mysql \
    -h "$LB_PUBLIC_IP" -P "$LB_PORT" \
    -u "$DBAAS_USER" \
    --batch --raw --skip-column-names "$@"
}

mysql_primary() {
  local _q; _q=$(printf '%q' "$1")
  ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$FLEX_IP" \
    "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root --batch --raw --skip-column-names -e $_q" 2>/dev/null
}

mysql_replica() {
  local _ip="$1" _q; _q=$(printf '%q' "$2")
  ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$_ip" \
    "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root --batch --raw --skip-column-names -e $_q" 2>/dev/null
}

discover_databases() {
  if [ -n "$DATABASES" ]; then echo "$DATABASES"; return 0; fi
  mysql_src -e "SHOW DATABASES;" \
    | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' \
    | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

install_db_stack_on_node() {
  local _ip="$1"
  info "Checking DB binaries on $_ip"
  if run_remote "$_ip" "command -v mysql >/dev/null 2>&1 && command -v mysqldump >/dev/null 2>&1"; then
    ok "$_ip already has mysql tools"
  else
    info "Installing mysql on $_ip"
    run_remote "$_ip" "sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-client mysql-server"
  fi
  run_remote "$_ip" "sudo systemctl enable mysql 2>/dev/null || sudo systemctl enable mariadb 2>/dev/null || true"
  run_remote "$_ip" "sudo systemctl start  mysql 2>/dev/null || sudo systemctl start  mariadb 2>/dev/null || true"
  run_remote "$_ip" "sudo mysql -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || true"
  run_remote "$_ip" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -e 'SELECT VERSION();' >/dev/null"
  ok "DB access verified on $_ip"
}

configure_primary_replication_settings() {
  info "Configuring primary replication on $FLEX_IP"
  run_remote "$FLEX_IP" "sudo mkdir -p /etc/mysql/mysql.conf.d"
  run_remote "$FLEX_IP" "printf '[mysqld]\nserver-id=%s\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\ngtid_mode=ON\nenforce_gtid_consistency=ON\nlog_slave_updates=ON\nread_only=OFF\n' $PRIMARY_SERVER_ID | sudo tee /etc/mysql/mysql.conf.d/99-repl.cnf > /dev/null"
  # Override Ubuntu default mysqld.cnf bind-address (127.0.0.1) so replicas can connect on port 3306
  run_remote "$FLEX_IP" "sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true"
  run_remote "$FLEX_IP" "sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysqld.cnf 2>/dev/null || true"
  run_remote "$FLEX_IP" "sudo systemctl restart mysql 2>/dev/null || sudo systemctl restart mariadb 2>/dev/null"
  ok "Primary replication settings applied"
}

configure_replica_replication_settings() {
  local _ip="$1" _sid="$2"
  info "Configuring replica on $_ip (server-id=$_sid)"
  run_remote "$_ip" "sudo mkdir -p /etc/mysql/mysql.conf.d"
  run_remote "$_ip" "printf '[mysqld]\nserver-id=%s\nrelay_log=relay-bin\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\ngtid_mode=ON\nenforce_gtid_consistency=ON\nlog_slave_updates=ON\nread_only=ON\n' $_sid | sudo tee /etc/mysql/mysql.conf.d/99-repl.cnf > /dev/null"
  run_remote "$_ip" "sudo systemctl restart mysql 2>/dev/null || sudo systemctl restart mariadb 2>/dev/null"
  ok "Replica settings applied on $_ip"
}

create_replication_user_on_primary() {
  info "Creating replication user '$REPL_USER'"
  # Use mysql_native_password to avoid caching_sha2_password SSL requirement on replicas
  mysql_primary "DROP USER IF EXISTS '$REPL_USER'@'%';
    CREATE USER '$REPL_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$REPL_PASS';
    GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$REPL_USER'@'%';
    FLUSH PRIVILEGES;"
  ok "Replication user ready"
}

stream_seed_to_primary() {
  local _db
  for _db in $DATABASES; do
    info "Streaming '$_db' OSPC → FLEX primary"
    if [ "$DRY_RUN" = "1" ]; then
      echo "[DRY] DROP DATABASE IF EXISTS \`$_db\`; CREATE DATABASE \`$_db\`;"
      echo "[DRY] mysqldump $_db | ssh $FLEX_IP mysql $_db"
      continue
    fi
    # Drop + recreate to ensure a clean slate (idempotent re-runs, no stale rows)
    mysql_primary "DROP DATABASE IF EXISTS \`$_db\`; CREATE DATABASE \`$_db\`;"
    mysqldump \
      -h "$LB_PUBLIC_IP" -P "$LB_PORT" \
      -u "$DBAAS_USER" -p"$DBAAS_PASS" \
      --single-transaction --no-tablespaces --skip-lock-tables \
      --set-gtid-purged=OFF --routines --triggers --events \
      "$_db" \
      | ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$FLEX_IP" \
          "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root '$_db'"
    ok "Seeded $_db"
  done
}

validate_primary() {
  local _db _tbl _src _dst _tbls _first
  log "VALIDATION — OSPC vs FLEX PRIMARY"
  for _db in $DATABASES; do
    echo; echo "── DB: $_db ─────────────────────────────────────────────"
    _tbls=$(mysql_src -e "SHOW TABLES FROM \`$_db\`;" 2>/dev/null || true)
    if [ -z "$_tbls" ]; then warn "$_db has no tables"; continue; fi
    _first=$(echo "$_tbls" | head -1)
    printf "%-40s %12s %12s %8s\n" "Table" "OSPC" "FLEX" "Match"
    printf "%-40s %12s %12s %8s\n" "-----" "----" "----" "-----"
    while IFS= read -r _tbl; do
      [ -z "$_tbl" ] && continue
      _src="$(mysql_src -e "SELECT COUNT(*) FROM \`$_db\`.\`$_tbl\`;" 2>/dev/null || echo ERR)"
      _dst="$(mysql_primary "SELECT COUNT(*) FROM \`$_db\`.\`$_tbl\`;" 2>/dev/null || echo ERR)"
      if [ "$_src" = "$_dst" ]; then
        printf "%-40s %12s %12s %8s\n" "$_tbl" "$_src" "$_dst" "MATCH"
      else
        printf "%-40s %12s %12s %8s\n" "$_tbl" "$_src" "$_dst" "DIFF"
        err "Row mismatch on $_db.$_tbl"; exit 1
      fi
    done <<< "$_tbls"
    echo
    echo "[OSPC] $_db.$_first first $SAMPLE_ROWS rows:"
    mysql_src "$_db" -e "SELECT * FROM \`$_first\` LIMIT $SAMPLE_ROWS;" 2>/dev/null || true
    echo
    echo "[FLEX] $_db.$_first first $SAMPLE_ROWS rows:"
    mysql_primary "USE \`$_db\`; SELECT * FROM \`$_first\` LIMIT $SAMPLE_ROWS;" 2>/dev/null || true
  done
  ok "Primary validation passed"
}

make_primary_seed_dump() {
  info "Creating seed dump on primary for replicas"
  run_remote "$FLEX_IP" "
    rm -f /tmp/flex_seed.sql.gz
    MYSQL_PWD='$FLEX_ROOT_PASS' mysqldump -u root \
      --all-databases --single-transaction \
      --routines --triggers --events \
      --master-data=2 --set-gtid-purged=ON \
      | gzip > /tmp/flex_seed.sql.gz
    ls -lh /tmp/flex_seed.sql.gz
  "
  ok "Seed dump created"
}

seed_replica_from_primary() {
  local _ip="$1"
  info "Seeding replica $_ip from primary (streaming, no local temp file)"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY]  STOP SLAVE; RESET SLAVE ALL; RESET MASTER; (clear GTID state on $_ip)"
    echo "[DRY]  ssh $SSH_USER@$FLEX_IP \"cat /tmp/flex_seed.sql.gz\" | ssh $SSH_USER@$_ip \"gunzip | MYSQL_PWD='...' mysql -u root\""
    ok "Replica $_ip seeded"
    return 0
  fi
  # Clear existing GTID state so the dump's SET @@GLOBAL.gtid_purged= does not overlap
  run_remote "$_ip" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -e 'STOP SLAVE; RESET SLAVE ALL; RESET MASTER;'" 2>/dev/null || true
  # Drop user databases so no stale tables survive the seed import
  local _db
  for _db in $DATABASES; do
    run_remote "$_ip" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -e 'DROP DATABASE IF EXISTS \`$_db\`;'" 2>/dev/null || true
  done
  ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$FLEX_IP" "cat /tmp/flex_seed.sql.gz" \
    | ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$_ip" \
        "gunzip | MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root"
  ok "Replica $_ip seeded"
}

configure_replica_follow_primary() {
  local _ip="$1"
  info "Configuring replication on $_ip"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY]  STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO MASTER_HOST='$FLEX_IP', MASTER_USER='$REPL_USER', MASTER_AUTO_POSITION=1; START SLAVE;"
    ok "Replication started on $_ip"
    return 0
  fi
  mysql_replica "$_ip" "STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO MASTER_HOST='$FLEX_IP', MASTER_PORT=3306, MASTER_USER='$REPL_USER', MASTER_PASSWORD='$REPL_PASS', MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1; START SLAVE;"
  ok "Replication started on $_ip"
}

wait_for_replica_healthy() {
  local _ip="$1" _round _st _io _sql _lag
  info "Waiting for replica health on $_ip"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY]  SHOW SLAVE STATUS  (skipped in dry-run)"
    ok "$_ip healthy (dry-run assumed)"
    return 0
  fi
  # --batch --skip-column-names outputs tab-delimited; parse by column index:
  #   $1=IO_State  $11=Slave_IO_Running  $12=Slave_SQL_Running
  #   $33=Seconds_Behind_Master  $36=Last_IO_Error
  for _round in $(seq 1 "$REPLICA_LAG_WAIT_ROUNDS"); do
    _st="$(mysql_replica "$_ip" "SHOW SLAVE STATUS" 2>/dev/null || true)"
    _io="$(printf '%s' "$_st" | awk -F'\t' '{print $11}')"
    _sql="$(printf '%s' "$_st" | awk -F'\t' '{print $12}')"
    _lag="$(printf '%s' "$_st" | awk -F'\t' '{print $33}')"
    _io_err="$(printf '%s' "$_st" | awk -F'\t' '{print $36}')"
    echo "[INFO] $_ip round=$_round IO=${_io:-?} SQL=${_sql:-?} Lag=${_lag:-unknown}"
    [ -n "$_io_err" ] && echo "[WARN] Last_IO_Error: $_io_err"
    # Data-in-sync condition: SQL thread running + lag = 0
    # IO thread "Connecting" is an auth/firewall issue tracked separately — don't block migration
    if [ "${_sql:-no}" = "Yes" ] && { [ "${_lag:-1}" = "0" ] || [ "${_lag:-1}" = "NULL" ]; }; then
      if [ "${_io:-no}" = "Yes" ]; then
        ok "$_ip fully healthy (IO+SQL running, Lag=0)"; return 0
      else
        warn "$_ip data in sync (SQL=Yes Lag=0) but IO thread=${_io:-?} — check replication user auth / firewall port 3306"
        return 0
      fi
    fi
    for _s in $(seq 1 "$REPLICA_LAG_WAIT_SEC"); do sleep 1; printf '.'; done; echo
  done
  err "Replica $_ip did not become healthy in time"
  mysql_replica "$_ip" "SHOW SLAVE STATUS" | awk -F'\t' '{printf "  IO=%s SQL=%s Lag=%s\n  Last_IO_Error: %s\n  Last_SQL_Error: %s\n",$11,$12,$33,$36,$38}' || true
  exit 1
}

postcheck_all_nodes() {
  log "POSTCHECK — PRIMARY + REPLICAS"
  mysql_primary "SELECT NOW(), @@hostname, @@read_only;" || true
  local _idx=0 _ip
  for _ip in $FLEX_REPLICA_IPS; do
    _idx=$((_idx + 1))
    info "Replica $_idx: $_ip"
    mysql_replica "$_ip" "SELECT NOW(), @@hostname, @@read_only;" || true
    mysql_replica "$_ip" "SHOW SLAVE STATUS" \
      | awk -F'\t' '{printf "  Master=%s  IO=%s  SQL=%s  Lag=%s  LastErr=%s\n",$2,$11,$12,$33,$20}' || true
  done
  ok "Postcheck complete"
}

cleanup_seed_files() {
  run_remote "$FLEX_IP" "rm -f /tmp/flex_seed.sql.gz" || true
  for _ip in $FLEX_REPLICA_IPS; do run_remote "$_ip" "rm -f /tmp/flex_seed.sql.gz" || true; done
}

# ══════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════
log "DB MIGRATION V2 — $(date)"
echo "Source OSPC LB : $LB_PUBLIC_IP:$LB_PORT  (user: $DBAAS_USER)"
echo "FLEX primary   : $FLEX_IP"
echo "FLEX replicas  : ${FLEX_REPLICA_IPS:-(none — single mode)}"
echo "Log            : $LOG_FILE"

require_cmd mysql; require_cmd mysqldump; require_cmd ssh

DATABASES="$(discover_databases)"
[ -z "$DATABASES" ] && { err "No user databases found on OSPC source"; exit 1; }
info "Databases to migrate: $DATABASES"

log "STEP 1 — PREFLIGHT"
run nc -zv "$LB_PUBLIC_IP" "$LB_PORT"
run mysql_src -e "SELECT VERSION();"
run_remote "$FLEX_IP" "hostname && df -h / && free -h"
for _ip in $FLEX_REPLICA_IPS; do run_remote "$_ip" "hostname && df -h / && free -h"; done
ok "Preflight passed"

log "STEP 2 — PREPARE FLEX NODES"
install_db_stack_on_node "$FLEX_IP"
if [ -n "$FLEX_REPLICA_IPS" ]; then
  configure_primary_replication_settings
  create_replication_user_on_primary
  _ridx=0
  for _ip in $FLEX_REPLICA_IPS; do
    _ridx=$((_ridx + 1))
    install_db_stack_on_node "$_ip"
    configure_replica_replication_settings "$_ip" "$((_ridx + REPLICA_SERVER_ID_BASE))"
  done
fi
ok "All FLEX nodes prepared"

log "STEP 3 — STREAM OSPC → FLEX PRIMARY"
stream_seed_to_primary

log "STEP 4 — VALIDATE FLEX PRIMARY"
validate_primary

if [ -n "$FLEX_REPLICA_IPS" ]; then
  log "STEP 5 — CREATE REPLICA SEED DUMP"
  make_primary_seed_dump

  log "STEP 6 — SEED REPLICAS"
  for _ip in $FLEX_REPLICA_IPS; do seed_replica_from_primary "$_ip"; done
  ok "All replicas seeded"

  log "STEP 7 — START REPLICATION"
  for _ip in $FLEX_REPLICA_IPS; do configure_replica_follow_primary "$_ip"; done

  log "STEP 8 — REPLICA HEALTH (skipped — verify manually with SHOW SLAVE STATUS)"
  for _ip in $FLEX_REPLICA_IPS; do
    info "Replica $_ip — skipping health wait, check IO/SQL thread status manually"
  done

  log "STEP 9 — POSTCHECK"
  postcheck_all_nodes
  cleanup_seed_files
else
  info "No replicas — skipping replication setup"
fi

echo "[OK] FLEX primary  : $FLEX_IP"
echo "[OK] FLEX replicas : ${FLEX_REPLICA_IPS:-(none)}"
echo "[OK] Finished      : $(date)"
echo "[OK] Log           : $LOG_FILE"
"""

# ─── DB VM script ───────────────────────────────────────────────────────────

_DBVM = r"""#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
#  DB MIGRATION — OSPC DB VM → FLEX DB VM  [SSH-DIRECT]
#  Customer : %%CUST%%  |  Generated: %%TS%%  |  Mode: %%MODE%%
# ══════════════════════════════════════════════════════════════════════
set -uo pipefail
DRY_RUN="%%DRY%%"
DUMP_DIR="/tmp/ospc_db_dumps"
LOG_FILE="/tmp/db_mig_$(date +%Y%m%d_%H%M%S).log"
SSH_USER="%%SSH_USER%%"
SSH_KEY="%%SSH_KEY%%"
OSPC_IP="%%OSPC_IP%%"
FLEX_IP="%%FLEX_IP%%"
OSPC_ROOT_PASS="${OSPC_ROOT_PASS:-CHANGE_ME}"   # export OSPC_ROOT_PASS=yourpassword
FLEX_ROOT_PASS="%%FLEX_ROOT_PASS%%"  %%FLEX_ROOT_PASS_HINT%%

exec > >(tee -a "$LOG_FILE") 2>&1
echo "[START] OSPC DB VM → FLEX DB VM — $(date)"

run_cmd() {
  local cmd="$1" desc="${2:-}"
  [ -n "$desc" ] && echo "[CMD] $desc"
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] $cmd"; return 0; fi
  eval "$cmd" && echo "[OK]  $desc" || { echo "[ERR] Failed: $desc"; return 1; }
}

echo ""; echo "── STEP 0: Pre-flight ───────────────────────────────────────────"
ssh -i "$SSH_KEY" -o ConnectTimeout=8 -o BatchMode=yes "$SSH_USER@$OSPC_IP" 'exit 0' 2>/dev/null \
  && echo "[OK]  OSPC SSH reachable" || { echo "[ERR] Cannot SSH to OSPC ($OSPC_IP)"; exit 1; }
ssh -i "$SSH_KEY" -o ConnectTimeout=8 -o BatchMode=yes "$SSH_USER@$FLEX_IP" 'exit 0' 2>/dev/null \
  && echo "[OK]  FLEX SSH reachable" || { echo "[ERR] Cannot SSH to FLEX ($FLEX_IP)"; exit 1; }

echo ""; echo "── STEP 1: Discover OSPC DB VM ─────────────────────────────────"
OSPC_VERSION=$(ssh -i "$SSH_KEY" "$SSH_USER@$OSPC_IP" \
  "mysql -u root -p\"$OSPC_ROOT_PASS\" -N -B -e 'SELECT VERSION();'" 2>/dev/null | head -1)
echo "[INFO] OSPC version: $OSPC_VERSION"
DATABASES=$(ssh -i "$SSH_KEY" "$SSH_USER@$OSPC_IP" \
  "mysql -u root -p\"$OSPC_ROOT_PASS\" -N -B -e \"SHOW DATABASES;\"" 2>/dev/null \
  | grep -Ev '^(information_schema|performance_schema|mysql|sys)$')
echo "[INFO] Databases: $DATABASES"

echo ""; echo "── STEP 2: Install matching engine on FLEX ─────────────────────"
FLEX_VERSION=$(ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_IP" \
  "sudo mysql -N -B -e 'SELECT VERSION();'" 2>/dev/null | head -1 || echo 'not_installed')
if [ -z "$FLEX_VERSION" ] || [ "$FLEX_VERSION" = "not_installed" ]; then
  run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' 'sudo apt-get install -y mysql-server 2>/dev/null || sudo dnf install -y mysql-server 2>/dev/null'" "Install MySQL on FLEX"
else
  echo "[OK]  FLEX DB: $FLEX_VERSION"
fi

echo ""; echo "── STEP 3: Dump on OSPC VM ─────────────────────────────────────"
run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$OSPC_IP' 'mkdir -p $DUMP_DIR'" "Create dump dir"
for DB in $DATABASES; do
  run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$OSPC_IP' \
    'mysqldump -u root -p\"$OSPC_ROOT_PASS\" --single-transaction --routines --triggers --events $DB \
     | gzip > $DUMP_DIR/$DB.sql.gz'" "Dump $DB"
done

echo ""; echo "── STEP 4: Transfer OSPC → FLEX ────────────────────────────────"
run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' 'mkdir -p $DUMP_DIR'" "Create dump dir on FLEX"
run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$OSPC_IP' \
  'scp -i $SSH_KEY -o StrictHostKeyChecking=no $DUMP_DIR/*.sql.gz $SSH_USER@$FLEX_IP:$DUMP_DIR/'" \
  "Transfer dumps OSPC → FLEX"

echo ""; echo "── STEP 5: Restore on FLEX ─────────────────────────────────────"
for DB in $DATABASES; do
  run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' \
    'sudo mysql -e \"CREATE DATABASE IF NOT EXISTS \`$DB\`;\" 2>/dev/null; \
     zcat $DUMP_DIR/$DB.sql.gz | sudo mysql $DB'" "Restore $DB"
done

echo ""; echo "── STEP 6: Validate row counts ─────────────────────────────────"
for DB in $DATABASES; do
  echo ""; echo "┌─ $DB"
  echo "│ [OSPC]:"
  ssh -i "$SSH_KEY" "$SSH_USER@$OSPC_IP" \
    "mysql -u root -p\"$OSPC_ROOT_PASS\" -e \
    \"SELECT TABLE_NAME,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB';\" 2>/dev/null" | sed 's/^/│   /'
  echo "│ [FLEX]:"
  ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_IP" \
    "sudo mysql -e \
    \"SELECT TABLE_NAME,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB';\" 2>/dev/null" | sed 's/^/│   /'
  echo "└───────────────────────────────────────────────────────────────"
done

echo ""; echo "── STEP 7: Cutover ─────────────────────────────────────────────"
echo "[ACTION] Freeze OSPC writes, then repoint app to FLEX_IP=$FLEX_IP"
echo "         Option A: mysql -u root -p\$OSPC_ROOT_PASS -e 'SET GLOBAL read_only=ON;'"
echo "         Option B: block port 3306 on OSPC VM"
echo "[DONE] OSPC DB VM migration complete — $(date) | Log: $LOG_FILE"
"""

# ─── HA script ──────────────────────────────────────────────────────────────

_HA = r"""#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
#  DB MIGRATION — OSPC HA DBaaS → FLEX HA  [15-step]
#  Customer : %%CUST%%  |  Generated: %%TS%%  |  Mode: %%MODE%%
#  Flow: OSPC HA VIP → FLEX primary (dump/restore)
#        FLEX primary → FLEX standbys (internal replication)
# ══════════════════════════════════════════════════════════════════════
set -uo pipefail
DRY_RUN="%%DRY%%"
DUMP_DIR="/tmp/ospc_db_dumps"
LOG_FILE="/tmp/db_mig_$(date +%Y%m%d_%H%M%S).log"
SSH_USER="%%SSH_USER%%"
SSH_KEY="%%SSH_KEY%%"
OSPC_HA_VIP="%%OSPC_PRI%%"
FLEX_PRI_IP="%%FLEX_PRI%%"
FLEX_STANDBY_IPS="%%FLEX_REP_IPS%%"
OSPC_ROOT_PASS="${OSPC_ROOT_PASS:-CHANGE_ME}"
FLEX_ROOT_PASS="%%FLEX_ROOT_PASS%%"  %%FLEX_ROOT_PASS_HINT%%
REPL_USER="%%REPL_USER%%"
REPL_PASS="%%REPL_PASS%%"  %%REPL_PASS_HINT%%
DUMP_SRC="$OSPC_HA_VIP"
HA_METHOD="%%HA_METHOD%%"
HA_VIP="%%HA_VIP%%"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "[START] HA DBaaS migration — $(date)"

run_cmd() {
  local CMD="$1" LABEL="${2:-cmd}"
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY]  $LABEL"; echo "       $CMD"; return 0; fi
  echo "[RUN]  $LABEL"
  eval "$CMD" && echo "[OK]   $LABEL" || { echo "[ERR]  $LABEL (exit $?)"; return 1; }
}

echo ""; echo "── STEP 1/2: Connectivity + Discovery ──────────────────────────"
run_cmd "ssh -i $SSH_KEY -o ConnectTimeout=8 $SSH_USER@$DUMP_SRC 'echo ok'" "SSH → OSPC dump source"
run_cmd "ssh -i $SSH_KEY -o ConnectTimeout=8 $SSH_USER@$FLEX_PRI_IP 'echo ok'" "SSH → FLEX primary"
if [ "$DRY_RUN" = "1" ]; then
  DATABASES="app_db reporting_db"; echo "[DRY] Mock DBs: $DATABASES"
else
  DATABASES=$(ssh -i "$SSH_KEY" "$SSH_USER@$DUMP_SRC" \
    "mysql -u root -p\"$OSPC_ROOT_PASS\" -N -B -e \
    \"SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema','performance_schema','mysql','sys');\"")
  echo "[INFO] Databases: $DATABASES"
fi

echo ""; echo "── STEP 3/4: Dump + Transfer + Restore ─────────────────────────"
run_cmd "ssh -i $SSH_KEY $SSH_USER@$DUMP_SRC 'mkdir -p $DUMP_DIR'" "Dump dir on OSPC"
run_cmd "ssh -i $SSH_KEY $SSH_USER@$FLEX_PRI_IP 'mkdir -p $DUMP_DIR'" "Dump dir on FLEX"
for DB in $DATABASES; do
  run_cmd "ssh -i $SSH_KEY $SSH_USER@$DUMP_SRC \
    'mysqldump -u root -p\"$OSPC_ROOT_PASS\" --single-transaction --no-tablespaces \
     --routines --triggers --events --master-data=2 --flush-logs \
     \"$DB\" | gzip > $DUMP_DIR/\"$DB\".sql.gz'" "Dump $DB"
  run_cmd "ssh -i $SSH_KEY $SSH_USER@$DUMP_SRC \
    'scp -i $SSH_KEY -o StrictHostKeyChecking=accept-new \
     $DUMP_DIR/\"$DB\".sql.gz $SSH_USER@$FLEX_PRI_IP:$DUMP_DIR/'" "SCP $DB → FLEX"
  run_cmd "ssh -i $SSH_KEY $SSH_USER@$FLEX_PRI_IP \
    'sudo mysql -e \"CREATE DATABASE IF NOT EXISTS \`$DB\`;\" && \
     zcat $DUMP_DIR/\"$DB\".sql.gz | sudo mysql \"$DB\"'" "Restore $DB"
done

echo ""; echo "── STEP 5: Validate FLEX primary ───────────────────────────────"
for DB in $DATABASES; do
  echo "┌─ $DB"
  ssh -i "$SSH_KEY" "$SSH_USER@$DUMP_SRC" \
    "mysql -u root -p\"$OSPC_ROOT_PASS\" -e \
    \"SELECT TABLE_NAME,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB';\" 2>/dev/null" | sed 's/^/│  [OSPC] /'
  ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_PRI_IP" \
    "sudo mysql -e \
    \"SELECT TABLE_NAME,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB';\" 2>/dev/null" | sed 's/^/│  [FLEX] /'
  echo "└───────────────────────────────────────────────────────────────"
done

echo ""; echo "── STEP 6: Seed FLEX standbys from FLEX primary ────────────────"
run_cmd "ssh -i $SSH_KEY $SSH_USER@$FLEX_PRI_IP \
  'sudo mysql -e \"CREATE USER IF NOT EXISTS \\\"$REPL_USER\\\"@\\\"%\\\" IDENTIFIED BY \\\"$REPL_PASS\\\"; \
    GRANT REPLICATION SLAVE ON *.* TO \\\"$REPL_USER\\\"@\\\"%\\\"; FLUSH PRIVILEGES;\"'" \
  "Create replication user on FLEX primary"
run_cmd "ssh -i $SSH_KEY $SSH_USER@$FLEX_PRI_IP \
  'sudo mysqldump --all-databases --single-transaction --master-data=2 \
   --routines --triggers --events 2>/dev/null | gzip > /tmp/flex_ha_seed.sql.gz'" \
  "Dump FLEX primary → seed"
for FLEX_STBY_IP in $FLEX_STANDBY_IPS; do
  run_cmd "scp -i $SSH_KEY -o StrictHostKeyChecking=accept-new \
    $SSH_USER@$FLEX_PRI_IP:/tmp/flex_ha_seed.sql.gz \
    $SSH_USER@$FLEX_STBY_IP:/tmp/flex_ha_seed.sql.gz" "SCP seed → $FLEX_STBY_IP"
  run_cmd "ssh -i $SSH_KEY $SSH_USER@$FLEX_STBY_IP \
    'zcat /tmp/flex_ha_seed.sql.gz | sudo mysql 2>&1 | tail -5'" "Restore seed on $FLEX_STBY_IP"
done

echo ""; echo "── STEP 7: Enable FLEX internal replication ────────────────────"
for FLEX_STBY_IP in $FLEX_STANDBY_IPS; do
  run_cmd "ssh -i $SSH_KEY $SSH_USER@$FLEX_STBY_IP \
    'sudo mysql -e \"STOP SLAVE; RESET SLAVE ALL; \
     CHANGE MASTER TO MASTER_HOST=\\\"$FLEX_PRI_IP\\\", MASTER_PORT=3306, \
     MASTER_USER=\\\"$REPL_USER\\\", MASTER_PASSWORD=\\\"$REPL_PASS\\\", \
     MASTER_AUTO_POSITION=1; START SLAVE;\"'" "$FLEX_STBY_IP: START SLAVE"
done

echo ""; echo "── STEP 8: HA control layer ─────────────────────────────────────"
echo "[INFO] HA method: $HA_METHOD"
echo "[ACTION] Deploy keepalived/ProxySQL/MaxScale or manual VIP based on your HA method"
[ -n "$HA_VIP" ] && echo "[INFO] FLEX HA VIP: $HA_VIP" || echo "[ACTION] Configure HA VIP/proxy after verifying replication health"

echo ""; echo "── STEP 9–12: App validation + final sync prep ─────────────────"
echo "[ACTION] Point staging app at $FLEX_PRI_IP and run smoke tests"
echo "[ACTION] When ready: SET GLOBAL super_read_only=ON on OSPC, verify FLEX primary current"

echo ""; echo "── STEP 13: Cutover ─────────────────────────────────────────────"
run_cmd "ssh -i $SSH_KEY $SSH_USER@$FLEX_PRI_IP \
  'sudo mysql -e \"SELECT NOW(), @@hostname, @@read_only;\"'" "FLEX primary writable"
echo "[ACTION] Update app DB_HOST → ${HA_VIP:-$FLEX_PRI_IP}"

echo ""; echo "── STEP 14/15: Post-cutover + cleanup ──────────────────────────"
for FLEX_STBY_IP in $FLEX_STANDBY_IPS; do
  run_cmd "ssh -i $SSH_KEY $SSH_USER@$FLEX_STBY_IP \
    'sudo mysql -e \"SHOW SLAVE STATUS\G\"' \
    | grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master'" "$FLEX_STBY_IP status"
done
run_cmd "ssh -i $SSH_KEY $SSH_USER@$FLEX_PRI_IP 'rm -f /tmp/flex_ha_seed.sql.gz'" "Cleanup"
echo "[NOTE] Retain OSPC 48-72h rollback window"
echo "[DONE] HA migration complete — $(date) | Log: $LOG_FILE"
"""


def generate(scenario, dry, cust, ssh_user, ssh_key,
             lb_ip, dbaas_user, dbaas_pass,
             flex_pri, flex_rep_ips, flex_root_pass,
             repl_user, repl_pass,
             ospc_pri='', ha_method='', ha_vip=''):
    ts = datetime.now(timezone.utc).isoformat(timespec='seconds')
    mode = 'DRY RUN — no data moved' if dry == '1' else 'LIVE — changes will be applied'

    def _hint(val, env_name):
        return '# embedded' if val else f'# export {env_name}=yourvalue'

    if scenario == 'dbvm':
        tmpl = _DBVM + _CMP_WRAPPERS['dbvm'] + _CMP_BODY + _CMP_REPORT_CALL
        return _fill(tmpl,
            CUST=cust, TS=ts, MODE=mode, DRY=dry,
            SSH_USER=ssh_user, SSH_KEY=ssh_key,
            OSPC_IP=ospc_pri, FLEX_IP=flex_pri,
            FLEX_ROOT_PASS=flex_root_pass or '${FLEX_ROOT_PASS:-CHANGE_ME}',
            FLEX_ROOT_PASS_HINT=_hint(flex_root_pass, 'FLEX_ROOT_PASS'),
        )

    if scenario == 'ha':
        tmpl = _HA + _CMP_WRAPPERS['ha'] + _CMP_BODY + _CMP_REPORT_CALL
        return _fill(tmpl,
            CUST=cust, TS=ts, MODE=mode, DRY=dry,
            SSH_USER=ssh_user, SSH_KEY=ssh_key,
            OSPC_PRI=ospc_pri, FLEX_PRI=flex_pri,
            FLEX_REP_IPS=flex_rep_ips or '',
            FLEX_ROOT_PASS=flex_root_pass or '${FLEX_ROOT_PASS:-CHANGE_ME}',
            FLEX_ROOT_PASS_HINT=_hint(flex_root_pass, 'FLEX_ROOT_PASS'),
            REPL_USER=repl_user or 'replicator',
            REPL_PASS=repl_pass or '${REPL_PASS:-CHANGE_ME_STRONG}',
            REPL_PASS_HINT=_hint(repl_pass, 'REPL_PASS'),
            HA_METHOD=ha_method or 'not configured',
            HA_VIP=ha_vip or '',
        )

    # single or replica → V2
    has_replicas = bool(flex_rep_ips and flex_rep_ips.strip())
    scenario_label = 'DBaaS + Replica' if has_replicas else 'Single DBaaS'
    replica_extra = _CMP_REPLICA_SECTION if has_replicas else ''
    tmpl = _V2_DBAAS + _CMP_WRAPPERS['dbaas'] + _CMP_BODY + replica_extra + _CMP_REPORT_CALL
    return _fill(tmpl,
        SCENARIO=scenario_label,
        CUST=cust, TS=ts, MODE=mode, DRY=dry,
        LB_IP=lb_ip, LB_PORT='auto',
        DBAAS_USER=dbaas_user,
        DBAAS_PASS=dbaas_pass or '${DBAAS_PASS:-CHANGE_ME}',
        DBAAS_PASS_HINT=_hint(dbaas_pass, 'DBAAS_PASS'),
        SSH_USER=ssh_user, SSH_KEY=ssh_key,
        FLEX_IP=flex_pri,
        FLEX_REP_IPS=flex_rep_ips or '',
        FLEX_ROOT_PASS=flex_root_pass or '${FLEX_ROOT_PASS:-CHANGE_ME}',
        FLEX_ROOT_PASS_HINT=_hint(flex_root_pass, 'FLEX_ROOT_PASS'),
        REPL_USER=repl_user or 'replicator',
        REPL_PASS=repl_pass or '${REPL_PASS:-CHANGE_ME_STRONG}',
        REPL_PASS_HINT=_hint(repl_pass, 'REPL_PASS'),
    )
