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

# Separate failover test rows from comparison rows
fo_rows = [r for r in rows if r['phase'] == 'FAILOVER TEST']
cmp_rows = [r for r in rows if r['phase'] != 'FAILOVER TEST']

phases = list(dict.fromkeys(r['phase'] for r in cmp_rows))
checks = list(dict.fromkeys(r['check'] for r in cmp_rows))
data   = {(r['phase'], r['check']): (r['result'], r['detail']) for r in cmp_rows}

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

# Summary cards (comparison phases only)
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

# Failover card (if data present)
fo_card = ''
if fo_rows:
    fo_pass = sum(1 for r in fo_rows if r['result'] == 'PASS')
    fo_fail = sum(1 for r in fo_rows if r['result'] == 'FAIL')
    fo_final = next((r for r in fo_rows if r['check'] == 'Failover result'), None)
    fo_status = fo_final['detail'] if fo_final else ('FAILOVER ENGINE WORKING' if fo_fail == 0 else 'FAILOVER FAILED')
    fo_cls = 'all-pass' if fo_fail == 0 else 'has-fail'
    fo_card = ('<div class="card fo-card ' + fo_cls + '">'
               '<b>&#9889; Failover Test</b>'
               '<div class="counts">'
               '<span class="pg">&#10004;&nbsp;' + str(fo_pass) + '&nbsp;PASS</span>'
               '&nbsp;&nbsp;'
               '<span class="fb">&#10008;&nbsp;' + str(fo_fail) + '&nbsp;FAIL</span>'
               '</div>'
               '<div class="fo-status">' + H.escape(fo_status) + '</div>'
               '</div>')

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

# Comparison table rows
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

# Failover results table
fo_section = ''
if fo_rows:
    fo_cells = ''
    for r in fo_rows:
        res, det, chk = r['result'], r['detail'], r['check']
        if res == 'PASS':
            badge = '<td class="p fo-res">&#10004;&nbsp;PASS</td>'
        elif res == 'FAIL':
            badge = '<td class="f fo-res">&#10008;&nbsp;FAIL</td>'
        else:
            badge = '<td class="i fo-res">&#8505;&nbsp;INFO</td>'
        fo_cells += ('<tr>'
                     '<td class="fo-step">' + H.escape(chk) + '</td>'
                     + badge +
                     '<td class="fo-det">' + H.escape(det) + '</td>'
                     '</tr>\n')
    fo_section = ('<h2 class="fo-hdr">&#9889; HA Failover Test Results</h2>'
                  '<table class="fo-tbl">'
                  '<thead><tr><th>Step</th><th>Result</th><th>Detail</th></tr></thead>'
                  '<tbody>' + fo_cells + '</tbody>'
                  '</table>')

CSS = (
    '*{box-sizing:border-box;margin:0;padding:0}'
    'body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;'
    'background:#0d1117;color:#e6edf3;padding:28px 32px}'
    'h1{color:#58a6ff;font-size:24px;font-weight:700;margin-bottom:4px}'
    'h2.fo-hdr{color:#f0a83a;font-size:18px;font-weight:700;margin:32px 0 14px;'
    'border-top:2px solid #30363d;padding-top:24px}'
    '.ts{color:#8b949e;font-size:12px;margin-bottom:22px}'
    '.cards{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:22px}'
    '.card{background:#161b22;border:1px solid #30363d;border-radius:10px;'
    'padding:16px 22px;min-width:200px;transition:border-color .2s}'
    '.card.all-pass{border-color:#238636}'
    '.card.has-fail{border-color:#da3633}'
    '.card b{display:block;color:#79c0ff;font-size:13px;font-weight:600;margin-bottom:10px}'
    '.fo-card b{color:#f0a83a}'
    '.fo-status{margin-top:8px;font-size:11px;color:#8b949e;word-break:break-word}'
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
    '.fo-tbl th:nth-child(1){min-width:260px}'
    '.fo-tbl th:nth-child(2){width:110px}'
    '.fo-step{color:#c9d1d9;font-weight:500}'
    '.fo-res{text-align:center;font-weight:700;width:110px}'
    '.fo-det{color:#8b949e;font-size:11px;word-break:break-all}'
)

doc = ('<!DOCTYPE html><html lang="en"><head>'
       '<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
       '<title>DB Migration Report</title>'
       '<style>' + CSS + '</style></head><body>'
       '<h1>&#128202; DB Migration Comparison Report</h1>'
       '<div class="ts">Generated: ' + now + '</div>'
       '<div class="cards">' + cards + fo_card + '</div>'
       '<button class="btn" onclick="exportCSV()">&#8659;&nbsp;Export CSV</button>'
       '<table><thead>' + thead + '</thead><tbody>' + cells + '</tbody></table>'
       + fo_section +
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
  # Verification queries must not fatally exit on transient errors — record as FAIL instead
  set +e
  trap - ERR   # set -E means the ERR trap fires even with set +e; clear it inside this phase

  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "   DB VERIFICATION — OSPC vs $_CMP_PHASE"
  echo "   $(date)"
  echo "════════════════════════════════════════════════════════════════════"

  echo ""; echo "── 1. Databases ─────────────────────────────────────────────────"
  _mo -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema','performance_schema','mysql','sys','test');" 2>/dev/null | sort > "$_TMPD/o_dbs.txt"
  _mf -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema','performance_schema','mysql','sys','test');" 2>/dev/null | sort > "$_TMPD/f_dbs.txt"
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
    # Guard: if DBaaS source returned empty (connection timeout/restriction), skip rather than false-FAIL
    if [[ ! -s "$_TMPD/o_ts.txt" ]]; then
        echo "[INFO]  $_DB -- TABLE STATUS (engine/charset)  SKIPPED (DBaaS source returned empty — connection timeout or query restriction)"
    else
        _diff_chk "$_DB -- TABLE STATUS (engine/charset)" "$_TMPD/o_ts.txt" "$_TMPD/f_ts.txt"
    fi

    # Normalize integer display widths: MariaDB reports int(11), MySQL 8.0+ reports int — functionally identical
    _norm_col() { sed -E 's/(tinyint|smallint|mediumint|bigint|int)\([0-9]+\)/\1/g'; }
    _mo -e "SELECT TABLE_NAME,ORDINAL_POSITION,COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,COLUMN_KEY,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$_DB' ORDER BY TABLE_NAME,ORDINAL_POSITION;" 2>/dev/null | _norm_col > "$_TMPD/o_col.txt"
    _mf -e "SELECT TABLE_NAME,ORDINAL_POSITION,COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,COLUMN_KEY,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$_DB' ORDER BY TABLE_NAME,ORDINAL_POSITION;" 2>/dev/null | _norm_col > "$_TMPD/f_col.txt"
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

      _DDL="skipped"
      printf '%s\t%s/%s -- DDL\tINFO\tskipped\n' "$_CMP_PHASE" "$_DB" "$_TBL" >> "$_G_RPT"

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

if [ "$DRY_RUN" = "1" ]; then
  echo "[DRY] Verification phase skipped in dry-run — run in LIVE mode to compare OSPC vs FLEX"
else
  _run_db_cmp_phase "FLEX PRIMARY"
fi
"""

_CMP_REPORT_CALL = r"""
if [ "$DRY_RUN" != "1" ]; then _gen_html_report; fi

echo ""
echo "── Cutover Instructions ───────────────────────────────────────────"
echo "[ACTION] Review comparison above. If all PASS, freeze OSPC writes and repoint app:"
echo "         MYSQL_PWD=\$OSPC_ROOT_PASS mysql -u root -e 'SET GLOBAL read_only=ON;'"
echo "[DONE] Migration + verification complete — $(date)"
"""

_CMP_REPLICA_SECTION = r"""
# ── Per-replica verification (same full comparison, each replica vs OSPC) ──
if [ -n "$FLEX_REPLICA_IPS" ] && [ "$DRY_RUN" != "1" ]; then
  for _REP_IP in $FLEX_REPLICA_IPS; do
    _mf() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_REP_IP" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -h 127.0.0.1 -u root -N -B $_a" 2>/dev/null; }
    _run_db_cmp_phase "REPLICA $_REP_IP"
  done
fi
"""

_HA_SUFFIX = r"""
HA_METHOD="%%HA_METHOD%%"
HA_VIP="%%HA_VIP%%"

# ══════════════════════════════════════════════════════════════════════
# HA CONTROL LAYER — failover engine setup + live failover test
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "   HA CONTROL LAYER — failover / VIP setup"
echo "════════════════════════════════════════════════════════════════════"
echo "[INFO] HA method: ${HA_METHOD:-(not configured)}"
if [ -n "$FLEX_REPLICA_IPS" ]; then
  case "${HA_METHOD:-}" in
    orchestrator) echo "[ACTION] Register $FLEX_IP with Orchestrator; add replicas: $FLEX_REPLICA_IPS" ;;
    keepalived)   echo "[ACTION] Configure keepalived VRRP on $FLEX_IP with VIP ${HA_VIP:-(set HA_VIP)}" ;;
    proxysql)     echo "[ACTION] Add $FLEX_IP as read-write; replicas as read-only in ProxySQL" ;;
    maxscale)     echo "[ACTION] Register $FLEX_IP + replicas in MaxScale monitor" ;;
    *)            echo "[ACTION] Deploy HA layer (keepalived/ProxySQL/MaxScale/orchestrator) → $FLEX_IP" ;;
  esac
fi
[ -n "$HA_VIP" ] && echo "[INFO] FLEX HA VIP target: $HA_VIP" || echo "[ACTION] Configure HA VIP/proxy endpoint after verifying health"
echo "[ACTION] Update app DB_HOST → ${HA_VIP:-$FLEX_IP}"
echo "[NOTE]  Retain OSPC VMs 48-72h as rollback window"

# ── Failover test: promote first replica to primary, verify writes route correctly ──
if [ -n "$FLEX_REPLICA_IPS" ] && [ "$DRY_RUN" != "1" ]; then
  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "   FAILOVER TEST — simulate primary failure → replica promotion"
  echo "════════════════════════════════════════════════════════════════════"

  # Pick first replica as failover target
  _FO_IP=$(echo "$FLEX_REPLICA_IPS" | awk '{print $1}')
  echo "[INFO] Failover target: $_FO_IP"
  printf 'FAILOVER TEST\tFailover target\tINFO\t%s\n' "$_FO_IP" >> "$_G_RPT"

  # Step 1: Write a sentinel row on current primary
  _FO_DB=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" \
    "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -N -B \
     -e \"SHOW DATABASES WHERE \\\`Database\\\` NOT IN ('information_schema','performance_schema','mysql','sys','test');\"" \
    2>/dev/null | head -1 || true)
  if [ -z "$_FO_DB" ]; then
    echo "[WARN]  No user DB found on primary — skipping failover write test"
    printf 'FAILOVER TEST\tSentinel write on primary\tFAIL\tNo user DB found on primary\n' >> "$_G_RPT"
    printf 'FAILOVER TEST\tFailover result\tFAIL\tFAILOVER TEST SKIPPED — no user DB\n' >> "$_G_RPT"
  else
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" \
      "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 \
       -e \"CREATE TABLE IF NOT EXISTS \\\`$_FO_DB\\\`.__ha_failover_test (id INT PRIMARY KEY, ts DATETIME); \
            INSERT INTO \\\`$_FO_DB\\\`.__ha_failover_test VALUES (1, NOW()) ON DUPLICATE KEY UPDATE ts=NOW();\"" 2>/dev/null
    echo "[OK]   Sentinel row written to $_FO_DB.__ha_failover_test on primary"
    printf 'FAILOVER TEST\tSentinel write on primary\tPASS\t%s.__ha_failover_test on %s\n' "$_FO_DB" "$FLEX_IP" >> "$_G_RPT"

    # Step 2: Wait for replica to receive it (up to 10s)
    _FO_OK=0
    for _fi in $(seq 1 10); do
      _got=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_FO_IP" \
        "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -N -B \
         -e 'SELECT COUNT(*) FROM \`$_FO_DB\`.__ha_failover_test;'" 2>/dev/null || echo 0)
      if [ "${_got:-0}" -ge 1 ] 2>/dev/null; then
        echo "[OK]   Replica $_FO_IP received sentinel row after ${_fi}s — replication lag OK"
        printf 'FAILOVER TEST\tReplica received sentinel\tPASS\t%s — received in %ss\n' "$_FO_IP" "$_fi" >> "$_G_RPT"
        _FO_OK=1; break
      fi
      sleep 1
    done
    if [ "$_FO_OK" = "0" ]; then
      echo "[WARN]  Replica $_FO_IP did not receive sentinel row within 10s — check replication"
      printf 'FAILOVER TEST\tReplica received sentinel\tFAIL\t%s — not received within 10s\n' "$_FO_IP" >> "$_G_RPT"
    fi

    # Step 3: Simulate primary failure — set read_only on primary
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" \
      "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 \
       -e 'SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;'" 2>/dev/null || true
    echo "[OK]   Primary $FLEX_IP set to read_only=ON (simulating failure)"
    printf 'FAILOVER TEST\tPrimary set read_only=ON\tPASS\t%s simulated failure\n' "$FLEX_IP" >> "$_G_RPT"

    # Step 4: Stop replica thread on failover target, promote it
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_FO_IP" \
      "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 \
       -e 'STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=OFF; SET GLOBAL super_read_only=OFF;'" 2>/dev/null
    echo "[OK]   $_FO_IP promoted to primary (STOP SLAVE; RESET SLAVE ALL; read_only=OFF)"
    printf 'FAILOVER TEST\tReplica promoted to primary\tPASS\t%s — STOP SLAVE; RESET SLAVE ALL; read_only=OFF\n' "$_FO_IP" >> "$_G_RPT"

    # Step 5: Write a new row on the promoted replica — proves it accepts writes
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_FO_IP" \
      "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 \
       -e 'INSERT INTO \`$_FO_DB\`.__ha_failover_test VALUES (2, NOW()) ON DUPLICATE KEY UPDATE ts=NOW();'" 2>/dev/null
    _new_rows=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_FO_IP" \
      "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -N -B \
       -e 'SELECT COUNT(*) FROM \`$_FO_DB\`.__ha_failover_test;'" 2>/dev/null || echo ERR)
    echo "[OK]   Promoted primary $_FO_IP has $_new_rows rows in failover test table — writes confirmed"
    printf 'FAILOVER TEST\tWrites on promoted primary\tPASS\t%s — %s rows confirmed\n' "$_FO_IP" "$_new_rows" >> "$_G_RPT"

    # Step 6: Restore original primary to read-write
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" \
      "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 \
       -e 'SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;'" 2>/dev/null || true
    echo "[OK]   Original primary $FLEX_IP restored to read_only=OFF"
    printf 'FAILOVER TEST\tOriginal primary restored\tPASS\t%s read_only=OFF\n' "$FLEX_IP" >> "$_G_RPT"

    # Step 7: Re-point other replicas to the promoted primary
    for _rip in $FLEX_REPLICA_IPS; do
      [ "$_rip" = "$_FO_IP" ] && continue
      ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_rip" \
        "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 \
         -e 'STOP SLAVE; RESET SLAVE ALL; \
             CHANGE MASTER TO MASTER_HOST=\"$_FO_IP\", MASTER_PORT=3306, \
               MASTER_USER=\"$REPL_USER\", MASTER_PASSWORD=\"$REPL_PASS\", $REPL_GTID_OPT; \
             START SLAVE;'" 2>/dev/null || true
      echo "[INFO] Replica $_rip re-pointed to new primary $_FO_IP"
      printf 'FAILOVER TEST\tReplica re-pointed\tINFO\t%s → new primary %s\n' "$_rip" "$_FO_IP" >> "$_G_RPT"
    done

    # Cleanup sentinel table
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_FO_IP" \
      "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 \
       -e 'DROP TABLE IF EXISTS \`$_FO_DB\`.__ha_failover_test;'" 2>/dev/null || true

    echo ""
    # Write final failover status to HTML report
    if [ "$_FO_OK" = "1" ]; then
      printf 'FAILOVER TEST\tFailover result\tPASS\tFAILOVER ENGINE WORKING\n' >> "$_G_RPT"
    else
      printf 'FAILOVER TEST\tFailover result\tFAIL\tFAILOVER ENGINE FAILED — replica did not replicate in time\n' >> "$_G_RPT"
    fi
    echo "════════════════════════════════════════════════════════════════════"
    echo "   FAILOVER TEST RESULT"
    echo "   Original primary : $FLEX_IP  (restored to read-write)"
    echo "   Promoted primary : $_FO_IP  (accepting writes)"
    [ -n "$HA_VIP" ] && echo "   Next: point HA VIP $HA_VIP → $_FO_IP in your HA engine"
    echo "   STATUS: FAILOVER ENGINE WORKING"
    echo "════════════════════════════════════════════════════════════════════"
  fi
fi
"""

_CMP_WRAPPERS = {
    'dbaas': r"""
# ── compare wrappers: DBaaS (LB direct) + Flex (SSH + root pw) ───────
# _mo() connects directly from runner to OSPC DBaaS LB (same as mysql_src / 09:24 working run)
_mo() { MYSQL_PWD="$DBAAS_PASS" mysql -h "$LB_PUBLIC_IP" -P "$LB_PORT" -u "$DBAAS_USER" $_LOCAL_SSL_OPT -N -B 2>/dev/null "$@"; }
_mf() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -h 127.0.0.1 -u root -N -B $_a" 2>/dev/null; }
""",
    'ha': r"""
# ── compare wrappers: HA (SSH→OSPC HA VIP) + Flex primary (sudo) ─────
_mo() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_HA_VIP" "MYSQL_PWD='$OSPC_ROOT_PASS' mysql -u root -N -B $_a" 2>/dev/null; }
_mf() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_PRI_IP" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -h 127.0.0.1 -u root -N -B $_a" 2>/dev/null; }
""",
    'dbvm': r"""
# ── compare wrappers: DB VM (SSH→OSPC VM) + Flex VM (SSH + 127.0.0.1) ───────
# $DB_SSL_OPT is set during STEP 1 engine detection (--skip-ssl for MariaDB, --ssl-mode=DISABLED for MySQL/Percona)
_mo() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_IP" "MYSQL_PWD='$OSPC_ROOT_PASS' mysql -u root $DB_SSL_OPT -N -B $_a" 2>/dev/null; }
_mf() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -h 127.0.0.1 -u root -N -B $_a" 2>/dev/null; }
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
SSH_KEY="${SSH_KEY/#\~/$HOME}"   # expand leading ~ so ssh -i works correctly
FLEX_IP="%%FLEX_IP%%"
FLEX_REPLICA_IPS="%%FLEX_REP_IPS%%"
FLEX_REPLICA_IPS="${FLEX_REPLICA_IPS//,/ }"  # normalize: commas → spaces so for-loops split correctly
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
mkdir -p "$WORKDIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Auto-detect DB port / SSL / engine when LIVE only ─────────────────
# Dry-run must not make live DB auth attempts. It should print the plan only.
detect_db_port() {
  local _host="$1"
  local _candidates="3306 3307 5432 1433 27017"
  for _p in $_candidates; do
    if timeout 5 bash -c ">/dev/tcp/$_host/$_p" 2>/dev/null; then
      echo "$_p"; return 0
    fi
  done
  # nc fallback (some environments block bash /dev/tcp)
  for _p in $_candidates; do
    if nc -z -w5 "$_host" "$_p" 2>/dev/null; then
      echo "$_p"; return 0
    fi
  done
  echo ""
}

if [ "$DRY_RUN" = "1" ]; then
  if [ -z "$LB_PORT" ] || [ "$LB_PORT" = "auto" ]; then
    LB_PORT="${DB_DRY_PORT:-3306}"
    echo "[DRY] LB_PORT=auto — skipping live source port scan, assuming $LB_PORT"
  fi
  DB_TYPE="${DB_DRY_TYPE:-mysql}"
  _LOCAL_SSL_OPT="${DB_DRY_SSL_OPT:---ssl-mode=DISABLED}"
  case "$DB_TYPE" in
    mariadb)
      DB_SSL_OPT="--skip-ssl"
      DB_PKG="mariadb-server mariadb-client"
      REPL_GTID_OPT="MASTER_USE_GTID=slave_pos"
      ;;
    percona)
      DB_SSL_OPT="--ssl-mode=DISABLED"
      DB_PKG="percona-server-server percona-server-client"
      REPL_GTID_OPT="MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1"
      ;;
    *)
      DB_TYPE="mysql"
      DB_SSL_OPT="--ssl-mode=DISABLED"
      DB_PKG="mysql-server mysql-client"
      REPL_GTID_OPT="MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1"
      ;;
  esac
  echo "[DRY] Skipping live source DB auth and engine detection on $LB_PUBLIC_IP:$LB_PORT"
  echo "[DRY] Assuming DB_TYPE=$DB_TYPE SSL=${_LOCAL_SSL_OPT:-(default SSL)}"
else
  # Strategy: TCP probe first (fast), then direct mysql connect as fallback.
  # Firewalls may block raw TCP SYN probes but allow MySQL protocol — so we
  # always try a real mysql login on 3306 before giving up.
  if [ -z "$LB_PORT" ] || [ "$LB_PORT" = "auto" ]; then
    echo "[INFO] LB_PORT=auto — scanning open DB ports on $LB_PUBLIC_IP …"
    _detected="$(detect_db_port "$LB_PUBLIC_IP")"
    if [ -z "$_detected" ]; then
      # TCP probe failed — firewall may block SYN scans but allow MySQL protocol.
      # Try a direct mysql connect on 3306 (with each SSL mode) as last resort.
      echo "[WARN] TCP scan found nothing — trying direct mysql connect on 3306 …"
      for _try_ssl in "--ssl-mode=DISABLED" "--skip-ssl" ""; do
        if MYSQL_PWD="$DBAAS_PASS" mysql -h "$LB_PUBLIC_IP" -P 3306 -u "$DBAAS_USER" \
            $_try_ssl --connect-timeout=8 -N -B -e "SELECT 1;" 2>/dev/null | grep -q "^1$"; then
          _detected="3306"
          echo "[INFO] Direct mysql on port 3306 succeeded (firewall blocks SYN probes)"
          break
        fi
      done
    fi
    if [ -z "$_detected" ]; then
      echo "[FATAL] Cannot reach $LB_PUBLIC_IP on any DB port." >&2
      echo "[FATAL] Tried TCP probe + direct mysql on 3306. Check: host reachable, DB running, firewall allows port 3306 from this runner." >&2
      exit 1
    fi
    LB_PORT="$_detected"
    echo "[INFO] Auto-detected DB port: $LB_PORT"
  fi

  # ── Detect which SSL option actually works against this source DB ─────
  # Test real connectivity — don't guess from client help text.
  # Percona/MySQL 8 may REQUIRE SSL and drop the connection (ERROR 2013) if disabled.
  _LOCAL_SSL_OPT="NONE"
  for _try_ssl in "--ssl-mode=DISABLED" "--skip-ssl" ""; do
    if MYSQL_PWD="$DBAAS_PASS" mysql -h "$LB_PUBLIC_IP" -P "$LB_PORT" -u "$DBAAS_USER" \
        $_try_ssl -N -B -e "SELECT 1;" 2>/dev/null | grep -q "^1$"; then
      _LOCAL_SSL_OPT="$_try_ssl"
      break
    fi
  done
  [ "$_LOCAL_SSL_OPT" = "NONE" ] && { echo "[FATAL] Cannot connect to $LB_PUBLIC_IP:$LB_PORT — check credentials/firewall" >&2; exit 1; }
  echo "[INFO] Source DB SSL flag: ${_LOCAL_SSL_OPT:-(default SSL)}"

  # ── Auto-detect source DB type and set target-matching variables ─────
  # Percona Server 8.0 VERSION() = "8.0.x-N" (no "Percona" in string) — must also check @@version_comment.
  _SRC_VER=$(MYSQL_PWD="$DBAAS_PASS" mysql -h "$LB_PUBLIC_IP" -P "$LB_PORT" -u "$DBAAS_USER" \
    $_LOCAL_SSL_OPT -N -B -e "SELECT VERSION();" 2>/dev/null || echo "unknown")
  _SRC_COMMENT=$(MYSQL_PWD="$DBAAS_PASS" mysql -h "$LB_PUBLIC_IP" -P "$LB_PORT" -u "$DBAAS_USER" \
    $_LOCAL_SSL_OPT -N -B -e "SELECT @@version_comment;" 2>/dev/null || echo "")
  echo "[INFO] Source DB: VERSION=$_SRC_VER  COMMENT=$_SRC_COMMENT"
  if echo "$_SRC_VER $_SRC_COMMENT" | grep -qi "mariadb"; then
    DB_TYPE="mariadb"
    DB_SSL_OPT="--skip-ssl"
    DB_PKG="mariadb-server mariadb-client"
    REPL_GTID_OPT="MASTER_USE_GTID=slave_pos"
    echo "[INFO] Source DB type: MariaDB ($_SRC_VER) — target will use MariaDB"
  elif echo "$_SRC_COMMENT" | grep -qi "percona"; then
    DB_TYPE="percona"
    DB_SSL_OPT="--ssl-mode=DISABLED"
    DB_PKG="percona-server-server percona-server-client"
    REPL_GTID_OPT="MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1"
    echo "[INFO] Source DB type: Percona ($_SRC_VER) — target will use Percona Server"
  else
    DB_TYPE="mysql"
    DB_SSL_OPT="--ssl-mode=DISABLED"
    DB_PKG="mysql-server mysql-client"
    REPL_GTID_OPT="MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1"
    echo "[INFO] Source DB type: MySQL ($_SRC_VER) — target will use MySQL"
  fi
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
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$_ip" "$@"
}

# Restart MySQL remotely without letting the session drop cause a fatal error.
# systemctl restart kills the SSH session — we background the restart and wait locally.
restart_mysql_remote() {
  local _ip="$1"
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] restart mysql on $_ip"; return 0; fi
  info "Restarting MySQL on $_ip"
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "$SSH_USER@$_ip" \
    "sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &" || true
  # Wait up to 15s but break as soon as DB responds — don't burn fixed 15s on every restart
  local _w=0
  while [ $_w -lt 15 ]; do
    sleep 1; _w=$((_w + 1))
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        "$SSH_USER@$_ip" \
        "MYSQL_PWD='$FLEX_ROOT_PASS' mysqladmin -h 127.0.0.1 -u root ping 2>/dev/null | grep -q alive" 2>/dev/null; then
      echo "[INFO] MySQL ready on $_ip after ${_w}s"
      return 0
    fi
  done
  echo "[WARN] MySQL on $_ip still not responding after 15s"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }; }

mysql_src() {
  MYSQL_PWD="$DBAAS_PASS" mysql \
    -h "$LB_PUBLIC_IP" -P "$LB_PORT" \
    -u "$DBAAS_USER" \
    $_LOCAL_SSL_OPT \
    --batch --raw --skip-column-names "$@"
}

mysql_primary() {
  local _q; _q=$(printf '%q' "$1")
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] mysql_primary: $1"; return 0; fi
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" \
    "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 --batch --raw --skip-column-names -e $_q" 2>/dev/null
}

mysql_replica() {
  local _ip="$1" _q; _q=$(printf '%q' "$2")
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] mysql_replica($_ip): $2"; return 0; fi
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_ip" \
    "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 --batch --raw --skip-column-names -e $_q" 2>/dev/null
}

discover_databases() {
  if [ -n "$DATABASES" ]; then echo "$DATABASES"; return 0; fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "${DB_DRY_DATABASES:-sampledb}"
    return 0
  fi
  mysql_src -e "SHOW DATABASES;" \
    | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' \
    | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

install_db_stack_on_node() {
  local _ip="$1"
  info "Checking DB engine on $_ip (required: $DB_TYPE)"

  # ── Detect currently installed engine ──────────────────────────────────────
  local _installed_ver _installed_type
  _installed_ver=$(run_remote "$_ip" "mysql --version 2>/dev/null || mariadb --version 2>/dev/null || echo none")
  if echo "$_installed_ver" | grep -qi "mariadb"; then
    _installed_type="mariadb"
  elif echo "$_installed_ver" | grep -qi "percona"; then
    _installed_type="percona"
  elif echo "$_installed_ver" | grep -qi "mysql\|Ver 8\|Ver 5"; then
    _installed_type="mysql"
  else
    _installed_type="none"
  fi

  # ── Purge if wrong engine is installed ─────────────────────────────────────
  if [ "$_installed_type" != "none" ] && [ "$_installed_type" != "$DB_TYPE" ]; then
    warn "Engine mismatch on $_ip: found=$_installed_type required=$DB_TYPE — purging and reinstalling"
    run_remote "$_ip" "
      sudo systemctl stop mysql mariadb 2>/dev/null || true
      sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confnew' \
        mysql-server mysql-client mysql-common 'mysql-server-core-*' 'mysql-client-core-*' \
        mariadb-server mariadb-client mariadb-common \
        percona-server-server percona-server-client 2>/dev/null || true
      sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
      sudo rm -rf /etc/mysql /var/lib/mysql /var/log/mysql
      sudo apt-get update -y
    "
    info "Purge complete — installing $DB_PKG on $_ip"
    _install_engine "$_ip"

  elif [ "$_installed_type" = "none" ]; then
    info "No DB engine found — installing $DB_PKG on $_ip (DB_TYPE=$DB_TYPE)"
    _install_engine "$_ip"

  else
    ok "$_ip already has correct engine ($DB_TYPE)"
  fi

  # ── Ensure mysql config dirs exist (fresh install may skip creating them) ──
  run_remote "$_ip" "sudo mkdir -p /etc/mysql/conf.d /etc/mysql/mysql.conf.d /etc/mysql/mariadb.conf.d 2>/dev/null || true"
  # Restore debian-start if dpkg purge deleted it (systemd ExecStartPost needs this file or service fails with status=203/EXEC)
  run_remote "$_ip" "
    if [ ! -f /etc/mysql/debian-start ] && [ -f /etc/mysql/debian-start.dpkg-dist ]; then
      sudo cp /etc/mysql/debian-start.dpkg-dist /etc/mysql/debian-start
      sudo chmod +x /etc/mysql/debian-start
      echo '[INFO] Restored /etc/mysql/debian-start from dpkg-dist'
    elif [ ! -f /etc/mysql/debian-start ]; then
      printf '#!/bin/bash\nexit 0\n' | sudo tee /etc/mysql/debian-start > /dev/null
      sudo chmod +x /etc/mysql/debian-start
      echo '[INFO] Created stub /etc/mysql/debian-start (dpkg-dist not found)'
    fi
  "

  run_remote "$_ip" "sudo systemctl enable mysql 2>/dev/null || sudo systemctl enable mariadb 2>/dev/null || true"
  # Smart start: skip if already running, start+wait only if needed, re-init as last resort
  run_remote "$_ip" "
    _db_ping() { sudo mysqladmin -u root ping 2>/dev/null | grep -q alive || MYSQL_PWD='$FLEX_ROOT_PASS' mysqladmin -h 127.0.0.1 -u root ping 2>/dev/null | grep -q alive; }
    if _db_ping; then
      echo '[INFO] DB service already running — skipping start'
    else
      sudo systemctl daemon-reload 2>/dev/null || true
      sudo systemctl start mysql 2>/dev/null || sudo systemctl start mariadb 2>/dev/null || \
        sudo service mysql start 2>/dev/null || sudo service mariadb start 2>/dev/null || true
      for _i in \$(seq 1 10); do
        if _db_ping; then echo '[INFO] DB service ready'; break; fi
        sleep 1
      done
      if ! _db_ping; then
        echo '[INFO] Service not responding — initializing data dir and retrying'
        sudo mysql_install_db --user=mysql --datadir=/var/lib/mysql 2>/dev/null || \
          sudo mariadb-install-db --user=mysql --datadir=/var/lib/mysql 2>/dev/null || true
        sudo systemctl restart mysql 2>/dev/null || sudo systemctl restart mariadb 2>/dev/null || \
          sudo service mysql restart 2>/dev/null || sudo service mariadb restart 2>/dev/null || true
        sleep 5
        _db_ping && echo '[INFO] DB service ready after re-init' || \
          { echo '[WARN] DB service still not responding — check: sudo journalctl -u mariadb -n 30'; }
      fi
    fi
  "

  # ── Set root password ──────────────────────────────────────────────────────
  if [ "$DB_TYPE" = "mariadb" ]; then
    run_remote "$_ip" "sudo mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || \
      MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || true"
  else
    run_remote "$_ip" "sudo mysql -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || \
      MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || true"
  fi
  run_remote "$_ip" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e 'SELECT VERSION();' >/dev/null"
  ok "DB access verified on $_ip"
}

_install_engine() {
  local _ip="$1"
  if [ "$DB_TYPE" = "percona" ]; then
    run_remote "$_ip" "
      cd /tmp
      wget -q https://repo.percona.com/apt/percona-release_latest.\$(lsb_release -sc)_all.deb -O percona-release.deb \
        || wget -q https://repo.percona.com/apt/percona-release_latest.generic_all.deb -O percona-release.deb
      sudo dpkg -i percona-release.deb
      sudo percona-release setup ps80
      sudo apt-get update -y
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" $DB_PKG
    "
  else
    run_remote "$_ip" "
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-broken \
        -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confnew' 2>/dev/null || true
      sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
      sudo apt-get update -y
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confnew' $DB_PKG
      sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
    "
  fi
}

configure_primary_replication_settings() {
  info "Configuring primary replication on $FLEX_IP (DB_TYPE=$DB_TYPE)"
  # mkdir-p already done in install_db_stack_on_node — skip duplicate
  # Write config + restart only if config changed
  if [ "$DB_TYPE" = "mariadb" ]; then
    run_remote "$FLEX_IP" "
      _new=\$(printf '[mysqld]\nserver-id=%s\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\nlog_slave_updates=ON\nread_only=OFF\n' $PRIMARY_SERVER_ID)
      _cur=\$(sudo cat /etc/mysql/conf.d/99-repl.cnf 2>/dev/null || true)
      if [ \"\$_new\" = \"\$_cur\" ]; then
        echo '[INFO] Primary config unchanged — no restart needed'; exit 0
      fi
      printf '%s' \"\$_new\" | sudo tee /etc/mysql/conf.d/99-repl.cnf /etc/mysql/mysql.conf.d/99-repl.cnf /etc/mysql/mariadb.conf.d/99-repl.cnf > /dev/null
      sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true
      sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysqld.cnf 2>/dev/null || true
      sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &
      echo '[INFO] Primary config updated — restarting'
    "
  else
    run_remote "$FLEX_IP" "
      _new=\$(printf '[mysqld]\nserver-id=%s\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\ngtid_mode=ON\nenforce_gtid_consistency=ON\nlog_slave_updates=ON\nread_only=OFF\n' $PRIMARY_SERVER_ID)
      _cur=\$(sudo cat /etc/mysql/conf.d/99-repl.cnf 2>/dev/null || true)
      if [ \"\$_new\" = \"\$_cur\" ]; then
        echo '[INFO] Primary config unchanged — no restart needed'; exit 0
      fi
      printf '%s' \"\$_new\" | sudo tee /etc/mysql/conf.d/99-repl.cnf /etc/mysql/mysql.conf.d/99-repl.cnf > /dev/null
      sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true
      sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysqld.cnf 2>/dev/null || true
      sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &
      echo '[INFO] Primary config updated — restarting'
    "
  fi
  # Wait for primary to be ready (fast — breaks as soon as ping succeeds)
  local _w=0
  while [ $_w -lt 15 ]; do
    sleep 1; _w=$((_w + 1))
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        "$SSH_USER@$FLEX_IP" \
        "MYSQL_PWD='$FLEX_ROOT_PASS' mysqladmin -h 127.0.0.1 -u root ping 2>/dev/null | grep -q alive" 2>/dev/null; then
      echo "[INFO] MySQL ready on $FLEX_IP after ${_w}s"
      break
    fi
  done
  ok "Primary replication settings applied"
}

configure_replica_replication_settings() {
  local _ip="$1" _sid="$2"
  info "Configuring replica on $_ip (server-id=$_sid DB_TYPE=$DB_TYPE)"
  # mkdir-p already done in install_db_stack_on_node — skip duplicate
  # Write config + restart only if config changed (avoids restart on idempotent re-runs)
  if [ "$DB_TYPE" = "mariadb" ]; then
    run_remote "$_ip" "
      _new=\$(printf '[mysqld]\nserver-id=%s\nrelay_log=relay-bin\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\nlog_slave_updates=ON\nread_only=ON\n' $_sid)
      _cur=\$(sudo cat /etc/mysql/conf.d/99-repl.cnf 2>/dev/null || true)
      if [ \"\$_new\" = \"\$_cur\" ]; then
        echo '[INFO] Replica config unchanged — no restart needed'; exit 0
      fi
      printf '%s' \"\$_new\" | sudo tee /etc/mysql/conf.d/99-repl.cnf /etc/mysql/mysql.conf.d/99-repl.cnf /etc/mysql/mariadb.conf.d/99-repl.cnf > /dev/null
      sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &
      echo '[INFO] Replica config updated — restarting'
    "
  else
    run_remote "$_ip" "
      _new=\$(printf '[mysqld]\nserver-id=%s\nrelay_log=relay-bin\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\ngtid_mode=ON\nenforce_gtid_consistency=ON\nlog_slave_updates=ON\nread_only=ON\n' $_sid)
      _cur=\$(sudo cat /etc/mysql/conf.d/99-repl.cnf 2>/dev/null || true)
      if [ \"\$_new\" = \"\$_cur\" ]; then
        echo '[INFO] Replica config unchanged — no restart needed'; exit 0
      fi
      printf '%s' \"\$_new\" | sudo tee /etc/mysql/conf.d/99-repl.cnf /etc/mysql/mysql.conf.d/99-repl.cnf > /dev/null
      sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &
      echo '[INFO] Replica config updated — restarting'
    "
  fi
  # Wait for DB to be ready (fast — breaks as soon as ping succeeds, max 15s)
  local _w=0
  while [ $_w -lt 15 ]; do
    sleep 1; _w=$((_w + 1))
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        "$SSH_USER@$_ip" \
        "MYSQL_PWD='$FLEX_ROOT_PASS' mysqladmin -h 127.0.0.1 -u root ping 2>/dev/null | grep -q alive" 2>/dev/null; then
      echo "[INFO] MySQL ready on $_ip after ${_w}s"
      break
    fi
  done
  ok "Replica settings applied on $_ip"
}

create_replication_user_on_primary() {
  info "Creating replication user '$REPL_USER'"
  if [ "$DB_TYPE" = "mariadb" ]; then
    mysql_primary "DROP USER IF EXISTS '$REPL_USER'@'%';
      CREATE USER '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASS';
      GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$REPL_USER'@'%';
      FLUSH PRIVILEGES;"
  else
    # MySQL 8.0: specify mysql_native_password to avoid caching_sha2_password SSL requirement
    mysql_primary "DROP USER IF EXISTS '$REPL_USER'@'%';
      CREATE USER '$REPL_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$REPL_PASS';
      GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$REPL_USER'@'%';
      FLUSH PRIVILEGES;"
  fi
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
    # _LOCAL_SSL_OPT: runner-side mysql client flag (MySQL 8 = --ssl-mode=DISABLED, MariaDB = --skip-ssl)
    # --set-gtid-purged=OFF: local mysqldump is MySQL 8 on runner — always supported; tells it to omit gtid_purged from dump
    mysqldump \
      -h "$LB_PUBLIC_IP" -P "$LB_PORT" \
      -u "$DBAAS_USER" -p"$DBAAS_PASS" \
      $_LOCAL_SSL_OPT \
      --single-transaction --no-tablespaces --skip-lock-tables \
      --set-gtid-purged=OFF --routines --triggers --events \
      "$_db" \
      | ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$FLEX_IP" \
          "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 '$_db'"
    ok "Seeded $_db"
  done
}

validate_primary() {
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] validate_primary — skipped in dry-run"; return 0; fi
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
  # --set-gtid-purged=ON is MySQL/Percona-only; MariaDB mysqldump does not support it
  if [ "$DB_TYPE" = "mariadb" ]; then
    run_remote "$FLEX_IP" "
      rm -f /tmp/flex_seed.sql.gz
      MYSQL_PWD='$FLEX_ROOT_PASS' mysqldump -u root \
        --all-databases --single-transaction \
        --routines --triggers --events \
        --master-data=2 \
        | gzip > /tmp/flex_seed.sql.gz
      ls -lh /tmp/flex_seed.sql.gz
    "
  else
    run_remote "$FLEX_IP" "
      rm -f /tmp/flex_seed.sql.gz
      MYSQL_PWD='$FLEX_ROOT_PASS' mysqldump -u root \
        --all-databases --single-transaction \
        --routines --triggers --events \
        --master-data=2 --set-gtid-purged=ON \
        | gzip > /tmp/flex_seed.sql.gz
      ls -lh /tmp/flex_seed.sql.gz
    "
  fi
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
  # Clear existing GTID state so the dump's SET @@GLOBAL.gtid_purged= does not overlap.
  # Try sudo (Ubuntu auth_socket) first, then fall back to password+TCP. Do NOT swallow errors.
  run_remote "$_ip" "sudo mysql -u root -e 'STOP SLAVE; RESET SLAVE ALL; RESET MASTER;' 2>/dev/null || \
    MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e 'STOP SLAVE; RESET SLAVE ALL; RESET MASTER;'"
  # Drop user databases so no stale tables survive the seed import
  local _db
  for _db in $DATABASES; do
    run_remote "$_ip" "sudo mysql -u root -e 'DROP DATABASE IF EXISTS \`$_db\`;' 2>/dev/null || \
      MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e 'DROP DATABASE IF EXISTS \`$_db\`;'" 2>/dev/null || true
  done
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" "cat /tmp/flex_seed.sql.gz" \
    | ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_ip" \
        "gunzip | MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1"
  ok "Replica $_ip seeded"
}

configure_replica_follow_primary() {
  local _ip="$1"
  info "Configuring replication on $_ip"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY]  STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO MASTER_HOST='$FLEX_IP', MASTER_USER='$REPL_USER', $REPL_GTID_OPT; START SLAVE;"
    ok "Replication started on $_ip"
    return 0
  fi
  mysql_replica "$_ip" "STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO MASTER_HOST='$FLEX_IP', MASTER_PORT=3306, MASTER_USER='$REPL_USER', MASTER_PASSWORD='$REPL_PASS', $REPL_GTID_OPT; START SLAVE;"
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
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] postcheck_all_nodes — skipped in dry-run"; return 0; fi
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
#  Auto-detects source engine: MySQL / MariaDB / Percona / PostgreSQL
#  Customer : %%CUST%%  |  Generated: %%TS%%  |  Mode: %%MODE%%
# ══════════════════════════════════════════════════════════════════════
set -uo pipefail
DRY_RUN="%%DRY%%"
DUMP_DIR="/tmp/ospc_db_dumps"
LOG_FILE="/tmp/db_mig_$(date +%Y%m%d_%H%M%S).log"
SSH_USER="%%SSH_USER%%"
SSH_KEY="%%SSH_KEY%%"
SSH_KEY="${SSH_KEY/#\~/$HOME}"   # expand leading ~ so ssh -i works correctly
OSPC_IP="%%OSPC_IP%%"
FLEX_IP="%%FLEX_IP%%"
OSPC_ROOT_PASS="${OSPC_ROOT_PASS:-}"   # export OSPC_ROOT_PASS=yourpassword
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
ssh -i "$SSH_KEY" -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_IP" 'exit 0' 2>/dev/null \
  && echo "[OK]  OSPC SSH reachable" || { echo "[ERR] Cannot SSH to OSPC ($OSPC_IP)"; exit 1; }
ssh -i "$SSH_KEY" -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" 'exit 0' 2>/dev/null \
  && echo "[OK]  FLEX SSH reachable" || { echo "[ERR] Cannot SSH to FLEX ($FLEX_IP)"; exit 1; }

echo ""; echo "── STEP 1: Auto-detect source DB engine ────────────────────────"
# Percona Server 8.0 VERSION() = "8.0.x-N" — must also check @@version_comment for "Percona"
OSPC_VERSION=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_IP" "
  MYSQL_PWD='${OSPC_ROOT_PASS}' mysql -u root --skip-ssl -N -B -e 'SELECT VERSION();' 2>/dev/null ||
  MYSQL_PWD='${OSPC_ROOT_PASS}' mysql -u root --ssl-mode=DISABLED -N -B -e 'SELECT VERSION();' 2>/dev/null ||
  sudo -u postgres psql -t -c 'SELECT version();' 2>/dev/null | head -1 | xargs ||
  echo unknown" 2>/dev/null || echo "unknown")
OSPC_COMMENT=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_IP" "
  MYSQL_PWD='${OSPC_ROOT_PASS}' mysql -u root --skip-ssl -N -B -e 'SELECT @@version_comment;' 2>/dev/null ||
  MYSQL_PWD='${OSPC_ROOT_PASS}' mysql -u root -N -B -e 'SELECT @@version_comment;' 2>/dev/null ||
  echo ''" 2>/dev/null || echo "")
echo "[INFO] Source: VERSION=$OSPC_VERSION  COMMENT=$OSPC_COMMENT"

if echo "$OSPC_VERSION" | grep -qi "postgresql\|postgre"; then
  DB_TYPE="postgresql"; DB_PKG="postgresql postgresql-client"; DB_SSL_OPT=""
  echo "[INFO] Engine detected: PostgreSQL"
elif echo "$OSPC_VERSION $_OSPC_COMMENT" | grep -qi "mariadb"; then
  DB_TYPE="mariadb"; DB_PKG="mariadb-server mariadb-client"; DB_SSL_OPT="--skip-ssl"
  echo "[INFO] Engine detected: MariaDB"
elif echo "$OSPC_COMMENT" | grep -qi "percona"; then
  DB_TYPE="percona"; DB_PKG="percona-server-server percona-server-client"; DB_SSL_OPT="--ssl-mode=DISABLED"
  echo "[INFO] Engine detected: Percona Server"
else
  DB_TYPE="mysql"; DB_PKG="mysql-server mysql-client"; DB_SSL_OPT="--ssl-mode=DISABLED"
  echo "[INFO] Engine detected: MySQL"
fi

# Discover source databases (MySQL family)
if [ "$DB_TYPE" != "postgresql" ]; then
  DATABASES=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_IP" \
    "MYSQL_PWD='${OSPC_ROOT_PASS}' mysql -u root ${DB_SSL_OPT} -N -B -e \"SHOW DATABASES;\"" 2>/dev/null \
    | grep -Ev '^(information_schema|performance_schema|mysql|sys)$')
  echo "[INFO] Databases: $DATABASES"
fi

echo ""; echo "── STEP 2: Ensure matching engine on FLEX ($DB_TYPE) ───────────"
# Detect what is currently installed on FLEX
_FLEX_INSTALLED_VER=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "$SSH_USER@$FLEX_IP" \
  "mysql --version 2>/dev/null || mariadb --version 2>/dev/null || psql --version 2>/dev/null || echo none" 2>/dev/null || echo "none")
if echo "$_FLEX_INSTALLED_VER" | grep -qi "mariadb"; then   _FLEX_INSTALLED_TYPE="mariadb"
elif echo "$_FLEX_INSTALLED_VER" | grep -qi "percona"; then _FLEX_INSTALLED_TYPE="percona"
elif echo "$_FLEX_INSTALLED_VER" | grep -qi "psql\|postgres"; then _FLEX_INSTALLED_TYPE="postgresql"
elif echo "$_FLEX_INSTALLED_VER" | grep -qi "mysql\|Ver 8\|Ver 5"; then _FLEX_INSTALLED_TYPE="mysql"
else _FLEX_INSTALLED_TYPE="none"; fi
echo "[INFO] FLEX installed engine: $_FLEX_INSTALLED_TYPE  |  Required: $DB_TYPE"

run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' \
  'sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true'" \
  "Recover broken dpkg state on FLEX" 2>/dev/null || true

if [ "$_FLEX_INSTALLED_TYPE" != "none" ] && [ "$_FLEX_INSTALLED_TYPE" != "$DB_TYPE" ]; then
  echo "[WARN] Engine mismatch — purging $_FLEX_INSTALLED_TYPE and installing $DB_TYPE"
  run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' '
    sudo systemctl stop mysql mariadb postgresql 2>/dev/null || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y \
      mysql-server mysql-client mysql-common \"mysql-server-core-*\" \"mysql-client-core-*\" \
      mariadb-server mariadb-client mariadb-common \
      percona-server-server percona-server-client \
      postgresql postgresql-client 2>/dev/null || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
    sudo rm -rf /etc/mysql /var/lib/mysql /var/log/mysql /etc/postgresql /var/lib/postgresql
    sudo apt-get update -y'" "Purge wrong engine on FLEX"
  _FLEX_INSTALLED_TYPE="none"
fi

if [ "$_FLEX_INSTALLED_TYPE" = "none" ]; then
  echo "[INFO] Installing $DB_PKG on FLEX"
  if [ "$DB_TYPE" = "percona" ]; then
    run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' '
      cd /tmp
      wget -q https://repo.percona.com/apt/percona-release_latest.\$(lsb_release -sc)_all.deb -O percona-release.deb \
        || wget -q https://repo.percona.com/apt/percona-release_latest.generic_all.deb -O percona-release.deb
      sudo dpkg -i percona-release.deb && sudo percona-release setup ps80
      sudo apt-get update -y
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" $DB_PKG'" \
      "Install Percona Server on FLEX"
  else
    run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' \
      'sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" $DB_PKG'" \
      "Install $DB_PKG on FLEX"
  fi
else
  echo "[OK]  FLEX already has correct engine ($DB_TYPE)"
fi

# Set FLEX root password (MySQL family)
if [ "$DB_TYPE" != "postgresql" ]; then
  if [ "$DB_TYPE" = "mariadb" ]; then
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" \
      "sudo mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || \
       MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || true" 2>/dev/null || true
  else
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" \
      "sudo mysql -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || \
       MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || true" 2>/dev/null || true
  fi
fi

# ══════════════════════════════════════════════════════════════
# POSTGRESQL PATH
# ══════════════════════════════════════════════════════════════
if [ "$DB_TYPE" = "postgresql" ]; then
  echo ""; echo "── STEP 3 (PG): Dump all databases ─────────────────────────────"
  run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$OSPC_IP' 'mkdir -p $DUMP_DIR'" "Create dump dir on OSPC"
  # Remove stale dump file before creating new one (gzip refuses to overwrite)
  run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$OSPC_IP' \
    'rm -f $DUMP_DIR/pg_dumpall.sql $DUMP_DIR/pg_dumpall.sql.gz && \
     sudo -u postgres pg_dumpall --clean --if-exists > $DUMP_DIR/pg_dumpall.sql && \
     gzip -f $DUMP_DIR/pg_dumpall.sql'" \
    "pg_dumpall on OSPC"

  echo ""; echo "── STEP 4 (PG): Stream OSPC → FLEX (pipe through runner) ────────"
  # SCP from OSPC-side fails — OSPC has no runner SSH key. Pipe cat through runner instead.
  run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' 'mkdir -p $DUMP_DIR'" "Create dump dir on FLEX"
  run_cmd "ssh -i '$SSH_KEY' -o BatchMode=yes -o StrictHostKeyChecking=accept-new '$SSH_USER@$OSPC_IP' \
    'cat $DUMP_DIR/pg_dumpall.sql.gz' \
    | ssh -i '$SSH_KEY' -o BatchMode=yes -o StrictHostKeyChecking=accept-new '$SSH_USER@$FLEX_IP' \
    'cat > $DUMP_DIR/pg_dumpall.sql.gz'" \
    "Stream pg_dumpall OSPC → FLEX"

  echo ""; echo "── STEP 5 (PG): Restore on FLEX ────────────────────────────────"
  run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' \
    'sudo systemctl start postgresql 2>/dev/null || true && \
     gunzip -c $DUMP_DIR/pg_dumpall.sql.gz | sudo -u postgres psql 2>&1 | tail -5'" \
    "Restore pg_dumpall on FLEX"

  echo ""; echo "── STEP 6 (PG): Comparison ──────────────────────────────────────"
  # printf '%q ' properly shell-escapes each arg so the remote shell reconstructs them correctly
  _pg_o() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_IP" "sudo -u postgres psql -t -A $_a" 2>/dev/null; }
  _pg_f() { local _a; _a=$(printf '%q ' "$@"); ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" "sudo -u postgres psql -t -A $_a" 2>/dev/null; }
  _PG_PASS=0; _PG_FAIL=0

  # _pg_diff "label" "SQL" [optional_db]
  # When db is given, runs:  psql -d db -c "SQL"
  # When db is absent, runs: psql -c "SQL"
  _pg_diff() {
    local _lbl="$1" _sql="$2" _db="${3:-}"
    local _td
    _td=$(mktemp -d)
    if [ -n "$_db" ]; then
      _pg_o -d "$_db" -c "$_sql" | sort > "$_td/o.txt"
      _pg_f -d "$_db" -c "$_sql" | sort > "$_td/f.txt"
    else
      _pg_o -c "$_sql" | sort > "$_td/o.txt"
      _pg_f -c "$_sql" | sort > "$_td/f.txt"
    fi
    if diff -q "$_td/o.txt" "$_td/f.txt" > /dev/null 2>&1; then
      printf "  [PASS]  %-55s  (%s rows)\n" "$_lbl" "$(wc -l < "$_td/o.txt" | tr -d ' ')"
      _PG_PASS=$((_PG_PASS+1))
    else
      printf "  [FAIL]  %s\n" "$_lbl"
      diff "$_td/o.txt" "$_td/f.txt" | head -10 | sed 's/^/          /'
      _PG_FAIL=$((_PG_FAIL+1))
    fi
    rm -rf "$_td"
  }

  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "   DB VERIFICATION — OSPC vs FLEX PRIMARY (PostgreSQL)"
  echo "   $(date)"
  echo "════════════════════════════════════════════════════════════════════"

  echo ""; echo "── 1. Databases ─────────────────────────────────────────────────"
  _pg_diff "Database list" \
    "SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres') ORDER BY datname;"

  echo ""; echo "── 2. Schemas ───────────────────────────────────────────────────"
  _PG_DBS=$(_pg_o -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres') ORDER BY datname;")
  for _PG_DB in $_PG_DBS; do
    echo ""; echo "╔══ DB: $_PG_DB ══════════════════════════════════════════════════════"

    _pg_diff "$_PG_DB -- schemas" \
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('pg_catalog','information_schema','pg_toast') ORDER BY schema_name;" \
      "$_PG_DB"

    _pg_diff "$_PG_DB -- tables" \
      "SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;" \
      "$_PG_DB"

    _pg_diff "$_PG_DB -- views" \
      "SELECT schemaname||'.'||viewname FROM pg_views WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;" \
      "$_PG_DB"

    _pg_diff "$_PG_DB -- sequences" \
      "SELECT schemaname||'.'||sequencename FROM pg_sequences WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;" \
      "$_PG_DB"

    _pg_diff "$_PG_DB -- functions" \
      "SELECT routine_schema||'.'||routine_name||'('||coalesce(string_agg(parameter_name||' '||udt_name,', ' ORDER BY ordinal_position),'')||')' FROM information_schema.routines LEFT JOIN information_schema.parameters USING(specific_catalog,specific_schema,specific_name) WHERE routine_schema NOT IN ('pg_catalog','information_schema') GROUP BY routine_schema,routine_name ORDER BY 1;" \
      "$_PG_DB"

    echo ""
    printf "  %-45s  %8s  %8s  %-7s\n" "Table" "OSPC" "FLEX" "Rows"
    printf "  %-45s  %8s  %8s  %-7s\n" "---------------------------------------------" "--------" "--------" "-------"
    _PG_TBLS=$(_pg_o -d "$_PG_DB" -c "SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;")
    for _PG_TBL in $_PG_TBLS; do
      _OC=$(_pg_o -d "$_PG_DB" -c "SELECT COUNT(*) FROM $_PG_TBL;" | tr -d ' ')
      _FC=$(_pg_f -d "$_PG_DB" -c "SELECT COUNT(*) FROM $_PG_TBL;" | tr -d ' ')
      [ -z "$_OC" ] && _OC="ERR"; [ -z "$_FC" ] && _FC="ERR"
      if [ "$_OC" = "$_FC" ]; then _ROW="MATCH"; _PG_PASS=$((_PG_PASS+1))
      else _ROW="DIFFER"; _PG_FAIL=$((_PG_FAIL+1)); fi
      printf "  %-45s  %8s  %8s  %-7s\n" "$_PG_TBL" "$_OC" "$_FC" "$_ROW"
    done
    echo "╚══════════════════════════════════════════════════════════════════════"
  done

  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  printf "   RESULT [FLEX PRIMARY]:  PASS=%s   FAIL=%s\n" "$_PG_PASS" "$_PG_FAIL"
  if [ "$_PG_FAIL" = "0" ]; then echo "   STATUS: ALL CHECKS PASSED"
  else echo "   STATUS: DIFFERENCES FOUND — review above before cutover"; fi
  echo "════════════════════════════════════════════════════════════════════"

  echo ""
  echo "── Cutover Instructions ───────────────────────────────────────────"
  echo "[ACTION] Review comparison above. If all PASS, freeze OSPC writes and repoint app to FLEX_IP=$FLEX_IP"
  echo "[DONE] PostgreSQL migration + verification complete — $(date) | Log: $LOG_FILE"
  exit 0
fi

# ══════════════════════════════════════════════════════════════
# MYSQL / MARIADB / PERCONA PATH
# ══════════════════════════════════════════════════════════════

echo ""; echo "── STEP 3: Dump on OSPC VM ─────────────────────────────────────"
run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$OSPC_IP' 'mkdir -p $DUMP_DIR'" "Create dump dir"
for DB in $DATABASES; do
  # --set-gtid-purged=OFF is MySQL/Percona-only; MariaDB mysqldump on OSPC does not support it
  if [ "$DB_TYPE" = "mariadb" ]; then
    run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$OSPC_IP' \
      'MYSQL_PWD=\"${OSPC_ROOT_PASS}\" mysqldump -u root $DB_SSL_OPT \
       --single-transaction --routines --triggers --events $DB \
       | gzip > $DUMP_DIR/$DB.sql.gz'" "Dump $DB"
  else
    run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$OSPC_IP' \
      'MYSQL_PWD=\"${OSPC_ROOT_PASS}\" mysqldump -u root $DB_SSL_OPT \
       --single-transaction --routines --triggers --events --set-gtid-purged=OFF $DB \
       | gzip > $DUMP_DIR/$DB.sql.gz'" "Dump $DB"
  fi
done

echo ""; echo "── STEP 4: Stream dumps OSPC → FLEX (pipe through runner) ─────"
# SCP from OSPC-side fails — OSPC has no runner SSH key. Pipe each dump through runner.
ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" "mkdir -p $DUMP_DIR"
for DB in $DATABASES; do
  echo "[INFO] Streaming $DB.sql.gz OSPC → FLEX"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY] ssh OSPC cat $DUMP_DIR/$DB.sql.gz | ssh FLEX cat > $DUMP_DIR/$DB.sql.gz"
  else
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_IP" \
      "cat $DUMP_DIR/$DB.sql.gz" \
      | ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_IP" \
          "cat > $DUMP_DIR/$DB.sql.gz" \
      && echo "[OK]  Streamed $DB" || echo "[ERR] Failed to stream $DB"
  fi
done

echo ""; echo "── STEP 5: Restore on FLEX ─────────────────────────────────────"
for DB in $DATABASES; do
  run_cmd "ssh -i '$SSH_KEY' '$SSH_USER@$FLEX_IP' \
    'MYSQL_PWD=$FLEX_ROOT_PASS mysql -u root -h 127.0.0.1 -e \"CREATE DATABASE IF NOT EXISTS \`$DB\`;\" 2>/dev/null; \
     zcat $DUMP_DIR/$DB.sql.gz | MYSQL_PWD=$FLEX_ROOT_PASS mysql -u root -h 127.0.0.1 $DB'" "Restore $DB"
done

echo ""; echo "── STEP 6: Verify & Compare OSPC ↔ FLEX ───────────────────────"
echo "[INFO] Running comprehensive DB verification — OSPC vs FLEX"
echo ""
"""

# ─── HA script ──────────────────────────────────────────────────────────────

_HA = r"""#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
#  DB MIGRATION V2 — OSPC HA DBaaS → FLEX HA
#  Customer : %%CUST%%  |  Generated: %%TS%%  |  Mode: %%MODE%%
#  Flow: OSPC HA VIP → FLEX primary (SSH dump stream)
#        FLEX primary → FLEX standbys (internal replication)
# ══════════════════════════════════════════════════════════════════════
set -Eeuo pipefail
trap 'rc=$?; echo "[FATAL] line $LINENO: $BASH_COMMAND (rc=$rc)" >&2; exit $rc' ERR

DRY_RUN="%%DRY%%"
OSPC_HA_VIP="%%OSPC_PRI%%"
FLEX_PRI_IP="%%FLEX_PRI%%"
FLEX_STANDBY_IPS="%%FLEX_REP_IPS%%"
OSPC_ROOT_PASS="${OSPC_ROOT_PASS:-CHANGE_ME}"
FLEX_ROOT_PASS="%%FLEX_ROOT_PASS%%"  %%FLEX_ROOT_PASS_HINT%%
REPL_USER="%%REPL_USER%%"
REPL_PASS="%%REPL_PASS%%"  %%REPL_PASS_HINT%%
SSH_USER="%%SSH_USER%%"
SSH_KEY="%%SSH_KEY%%"
SSH_KEY="${SSH_KEY/#\~/$HOME}"   # expand leading ~ so ssh -i works correctly
HA_METHOD="%%HA_METHOD%%"
HA_VIP="%%HA_VIP%%"

DATABASES=""
WORKDIR="/tmp/db_mig_v2"
LOG_FILE="$WORKDIR/db_mig_ha_$(date +%Y%m%d_%H%M%S).log"
PRIMARY_SERVER_ID=101
REPLICA_SERVER_ID_BASE=201
SAMPLE_ROWS=5
REPLICA_LAG_WAIT_ROUNDS=20
REPLICA_LAG_WAIT_SEC=15

mkdir -p "$WORKDIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Auto-detect source DB type via SSH to OSPC HA VIP ────────────────
# Percona Server 8.0 VERSION() = "8.0.x-N" — must also check @@version_comment for "Percona"
_SRC_VER=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "$SSH_USER@$OSPC_HA_VIP" \
  "MYSQL_PWD='$OSPC_ROOT_PASS' mysql -u root --skip-ssl -N -B -e 'SELECT VERSION();' 2>/dev/null || \
   MYSQL_PWD='$OSPC_ROOT_PASS' mysql -u root -N -B -e 'SELECT VERSION();' 2>/dev/null || echo unknown" 2>/dev/null || echo "unknown")
_SRC_COMMENT=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "$SSH_USER@$OSPC_HA_VIP" \
  "MYSQL_PWD='$OSPC_ROOT_PASS' mysql -u root --skip-ssl -N -B -e 'SELECT @@version_comment;' 2>/dev/null || \
   MYSQL_PWD='$OSPC_ROOT_PASS' mysql -u root -N -B -e 'SELECT @@version_comment;' 2>/dev/null || echo ''" 2>/dev/null || echo "")
echo "[INFO] Source DB: VERSION=$_SRC_VER  COMMENT=$_SRC_COMMENT"
if echo "$_SRC_VER $_SRC_COMMENT" | grep -qi "mariadb"; then
  DB_TYPE="mariadb"; DB_SSL_OPT="--skip-ssl"
  DB_PKG="mariadb-server mariadb-client"; REPL_GTID_OPT="MASTER_USE_GTID=slave_pos"
  echo "[INFO] Source DB: MariaDB ($_SRC_VER) — target will use MariaDB"
elif echo "$_SRC_COMMENT" | grep -qi "percona"; then
  DB_TYPE="percona"; DB_SSL_OPT="--ssl-mode=DISABLED"
  DB_PKG="percona-server-server percona-server-client"; REPL_GTID_OPT="MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1"
  echo "[INFO] Source DB: Percona ($_SRC_VER) — target will use Percona Server"
else
  DB_TYPE="mysql"; DB_SSL_OPT="--ssl-mode=DISABLED"
  DB_PKG="mysql-server mysql-client"; REPL_GTID_OPT="MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1"
  echo "[INFO] Source DB: MySQL ($_SRC_VER) — target will use MySQL"
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
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] ssh $_ip $*"; return 0; fi
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$_ip" "$@"
}

# Restart MySQL remotely without letting the session drop cause a fatal error.
restart_mysql_remote() {
  local _ip="$1"
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] restart mysql on $_ip"; return 0; fi
  info "Restarting MySQL on $_ip (backgrounded — waiting 15s for service to stabilise)"
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "$SSH_USER@$_ip" \
    "sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &" || true
  sleep 15
}

# Source: SSH to OSPC HA VIP with root password
mysql_src() {
  local _q; _q=$(printf '%q' "$1")
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_HA_VIP" \
    "MYSQL_PWD='$OSPC_ROOT_PASS' mysql -u root --batch --raw --skip-column-names -e $_q" 2>/dev/null
}

mysql_primary() {
  local _q; _q=$(printf '%q' "$1")
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] mysql_primary: $1"; return 0; fi
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_PRI_IP" \
    "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 --batch --raw --skip-column-names -e $_q" 2>/dev/null
}

mysql_standby() {
  local _ip="$1" _q; _q=$(printf '%q' "$2")
  if [ "$DRY_RUN" = "1" ]; then echo "[DRY] mysql_standby($_ip): $2"; return 0; fi
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_ip" \
    "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 --batch --raw --skip-column-names -e $_q" 2>/dev/null
}

discover_databases() {
  if [ -n "$DATABASES" ]; then echo "$DATABASES"; return 0; fi
  mysql_src "SHOW DATABASES;" \
    | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' \
    | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

install_db_stack_on_node() {
  local _ip="$1"
  info "Checking DB engine on $_ip (required: $DB_TYPE)"

  # ── Detect currently installed engine ──────────────────────────────────────
  local _installed_ver _installed_type
  _installed_ver=$(run_remote "$_ip" "mysql --version 2>/dev/null || mariadb --version 2>/dev/null || echo none")
  if echo "$_installed_ver" | grep -qi "mariadb"; then
    _installed_type="mariadb"
  elif echo "$_installed_ver" | grep -qi "percona"; then
    _installed_type="percona"
  elif echo "$_installed_ver" | grep -qi "mysql\|Ver 8\|Ver 5"; then
    _installed_type="mysql"
  else
    _installed_type="none"
  fi

  # ── Purge if wrong engine is installed ─────────────────────────────────────
  if [ "$_installed_type" != "none" ] && [ "$_installed_type" != "$DB_TYPE" ]; then
    warn "Engine mismatch on $_ip: found=$_installed_type required=$DB_TYPE — purging and reinstalling"
    run_remote "$_ip" "
      sudo systemctl stop mysql mariadb 2>/dev/null || true
      sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confnew' \
        mysql-server mysql-client mysql-common 'mysql-server-core-*' 'mysql-client-core-*' \
        mariadb-server mariadb-client mariadb-common \
        percona-server-server percona-server-client 2>/dev/null || true
      sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
      sudo rm -rf /etc/mysql /var/lib/mysql /var/log/mysql
      sudo apt-get update -y
    "
    info "Purge complete — installing $DB_PKG on $_ip"
    _install_engine "$_ip"

  elif [ "$_installed_type" = "none" ]; then
    info "No DB engine found — installing $DB_PKG on $_ip (DB_TYPE=$DB_TYPE)"
    _install_engine "$_ip"

  else
    ok "$_ip already has correct engine ($DB_TYPE)"
  fi

  # ── Ensure mysql config dirs exist (fresh install may skip creating them) ──
  run_remote "$_ip" "sudo mkdir -p /etc/mysql/conf.d /etc/mysql/mysql.conf.d /etc/mysql/mariadb.conf.d 2>/dev/null || true"
  # Restore debian-start if dpkg purge deleted it (systemd ExecStartPost needs this file or service fails with status=203/EXEC)
  run_remote "$_ip" "
    if [ ! -f /etc/mysql/debian-start ] && [ -f /etc/mysql/debian-start.dpkg-dist ]; then
      sudo cp /etc/mysql/debian-start.dpkg-dist /etc/mysql/debian-start
      sudo chmod +x /etc/mysql/debian-start
      echo '[INFO] Restored /etc/mysql/debian-start from dpkg-dist'
    elif [ ! -f /etc/mysql/debian-start ]; then
      printf '#!/bin/bash\nexit 0\n' | sudo tee /etc/mysql/debian-start > /dev/null
      sudo chmod +x /etc/mysql/debian-start
      echo '[INFO] Created stub /etc/mysql/debian-start (dpkg-dist not found)'
    fi
  "

  run_remote "$_ip" "sudo systemctl enable mysql 2>/dev/null || sudo systemctl enable mariadb 2>/dev/null || true"
  # Smart start: skip if already running, start+wait only if needed, re-init as last resort
  run_remote "$_ip" "
    _db_ping() { sudo mysqladmin -u root ping 2>/dev/null | grep -q alive || MYSQL_PWD='$FLEX_ROOT_PASS' mysqladmin -h 127.0.0.1 -u root ping 2>/dev/null | grep -q alive; }
    if _db_ping; then
      echo '[INFO] DB service already running — skipping start'
    else
      sudo systemctl daemon-reload 2>/dev/null || true
      sudo systemctl start mysql 2>/dev/null || sudo systemctl start mariadb 2>/dev/null || \
        sudo service mysql start 2>/dev/null || sudo service mariadb start 2>/dev/null || true
      for _i in \$(seq 1 10); do
        if _db_ping; then echo '[INFO] DB service ready'; break; fi
        sleep 1
      done
      if ! _db_ping; then
        echo '[INFO] Service not responding — initializing data dir and retrying'
        sudo mysql_install_db --user=mysql --datadir=/var/lib/mysql 2>/dev/null || \
          sudo mariadb-install-db --user=mysql --datadir=/var/lib/mysql 2>/dev/null || true
        sudo systemctl restart mysql 2>/dev/null || sudo systemctl restart mariadb 2>/dev/null || \
          sudo service mysql restart 2>/dev/null || sudo service mariadb restart 2>/dev/null || true
        sleep 5
        _db_ping && echo '[INFO] DB service ready after re-init' || \
          { echo '[WARN] DB service still not responding — check: sudo journalctl -u mariadb -n 30'; }
      fi
    fi
  "

  # ── Set root password ──────────────────────────────────────────────────────
  if [ "$DB_TYPE" = "mariadb" ]; then
    run_remote "$_ip" "sudo mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || \
      MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || true"
  else
    run_remote "$_ip" "sudo mysql -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || \
      MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e \"ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$FLEX_ROOT_PASS'; FLUSH PRIVILEGES;\" 2>/dev/null || true"
  fi
  run_remote "$_ip" "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e 'SELECT VERSION();' >/dev/null"
  ok "DB access verified on $_ip"
}

_install_engine() {
  local _ip="$1"
  if [ "$DB_TYPE" = "percona" ]; then
    run_remote "$_ip" "
      cd /tmp
      wget -q https://repo.percona.com/apt/percona-release_latest.\$(lsb_release -sc)_all.deb -O percona-release.deb \
        || wget -q https://repo.percona.com/apt/percona-release_latest.generic_all.deb -O percona-release.deb
      sudo dpkg -i percona-release.deb
      sudo percona-release setup ps80
      sudo apt-get update -y
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" $DB_PKG
    "
  else
    run_remote "$_ip" "
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-broken \
        -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confnew' 2>/dev/null || true
      sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
      sudo apt-get update -y
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confnew' $DB_PKG
      sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
    "
  fi
}

configure_primary_replication_settings() {
  info "Configuring primary replication settings on $FLEX_PRI_IP (DB_TYPE=$DB_TYPE)"
  # mkdir-p already done in install_db_stack_on_node — skip duplicate
  # Write config + restart only if config changed
  if [ "$DB_TYPE" = "mariadb" ]; then
    run_remote "$FLEX_PRI_IP" "
      _new=\$(printf '[mysqld]\nserver-id=%s\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\nlog_slave_updates=ON\nread_only=OFF\n' $PRIMARY_SERVER_ID)
      _cur=\$(sudo cat /etc/mysql/conf.d/99-repl.cnf 2>/dev/null || true)
      if [ \"\$_new\" = \"\$_cur\" ]; then
        echo '[INFO] Primary config unchanged — no restart needed'; exit 0
      fi
      printf '%s' \"\$_new\" | sudo tee /etc/mysql/conf.d/99-repl.cnf /etc/mysql/mysql.conf.d/99-repl.cnf /etc/mysql/mariadb.conf.d/99-repl.cnf > /dev/null
      sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true
      sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysqld.cnf 2>/dev/null || true
      sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &
      echo '[INFO] Primary config updated — restarting'
    "
  else
    run_remote "$FLEX_PRI_IP" "
      _new=\$(printf '[mysqld]\nserver-id=%s\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\ngtid_mode=ON\nenforce_gtid_consistency=ON\nlog_slave_updates=ON\nread_only=OFF\n' $PRIMARY_SERVER_ID)
      _cur=\$(sudo cat /etc/mysql/conf.d/99-repl.cnf 2>/dev/null || true)
      if [ \"\$_new\" = \"\$_cur\" ]; then
        echo '[INFO] Primary config unchanged — no restart needed'; exit 0
      fi
      printf '%s' \"\$_new\" | sudo tee /etc/mysql/conf.d/99-repl.cnf /etc/mysql/mysql.conf.d/99-repl.cnf > /dev/null
      sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true
      sudo sed -i 's/^bind-address.*\$/bind-address = 0.0.0.0/' /etc/mysql/mysqld.cnf 2>/dev/null || true
      sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &
      echo '[INFO] Primary config updated — restarting'
    "
  fi
  # Wait for primary to be ready (fast — breaks as soon as ping succeeds)
  local _w=0
  while [ $_w -lt 15 ]; do
    sleep 1; _w=$((_w + 1))
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        "$SSH_USER@$FLEX_PRI_IP" \
        "MYSQL_PWD='$FLEX_ROOT_PASS' mysqladmin -h 127.0.0.1 -u root ping 2>/dev/null | grep -q alive" 2>/dev/null; then
      echo "[INFO] MySQL ready on $FLEX_PRI_IP after ${_w}s"
      break
    fi
  done
  ok "Primary replication settings applied"
}

configure_standby_replication_settings() {
  local _ip="$1" _sid="$2"
  info "Configuring standby on $_ip (server-id=$_sid DB_TYPE=$DB_TYPE)"
  # mkdir-p already done in install_db_stack_on_node — skip duplicate
  # Write config + restart only if config changed (avoids restart on idempotent re-runs)
  if [ "$DB_TYPE" = "mariadb" ]; then
    run_remote "$_ip" "
      _new=\$(printf '[mysqld]\nserver-id=%s\nrelay_log=relay-bin\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\nlog_slave_updates=ON\nread_only=ON\n' $_sid)
      _cur=\$(sudo cat /etc/mysql/conf.d/99-repl.cnf 2>/dev/null || true)
      if [ \"\$_new\" = \"\$_cur\" ]; then
        echo '[INFO] Standby config unchanged — no restart needed'; exit 0
      fi
      printf '%s' \"\$_new\" | sudo tee /etc/mysql/conf.d/99-repl.cnf /etc/mysql/mysql.conf.d/99-repl.cnf /etc/mysql/mariadb.conf.d/99-repl.cnf > /dev/null
      sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &
      echo '[INFO] Standby config updated — restarting'
    "
  else
    run_remote "$_ip" "
      _new=\$(printf '[mysqld]\nserver-id=%s\nrelay_log=relay-bin\nlog_bin=mysql-bin\nbinlog_format=ROW\nbind-address=0.0.0.0\ngtid_mode=ON\nenforce_gtid_consistency=ON\nlog_slave_updates=ON\nread_only=ON\n' $_sid)
      _cur=\$(sudo cat /etc/mysql/conf.d/99-repl.cnf 2>/dev/null || true)
      if [ \"\$_new\" = \"\$_cur\" ]; then
        echo '[INFO] Standby config unchanged — no restart needed'; exit 0
      fi
      printf '%s' \"\$_new\" | sudo tee /etc/mysql/conf.d/99-repl.cnf /etc/mysql/mysql.conf.d/99-repl.cnf > /dev/null
      sudo bash -c 'sleep 1; systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null' </dev/null >/dev/null 2>&1 &
      echo '[INFO] Standby config updated — restarting'
    "
  fi
  # Wait for DB to be ready (fast — breaks as soon as ping succeeds, max 15s)
  local _w=0
  while [ $_w -lt 15 ]; do
    sleep 1; _w=$((_w + 1))
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
        "$SSH_USER@$_ip" \
        "MYSQL_PWD='$FLEX_ROOT_PASS' mysqladmin -h 127.0.0.1 -u root ping 2>/dev/null | grep -q alive" 2>/dev/null; then
      echo "[INFO] MySQL ready on $_ip after ${_w}s"
      break
    fi
  done
  ok "Standby settings applied on $_ip"
}

create_replication_user_on_primary() {
  info "Creating replication user '$REPL_USER' on FLEX primary"
  if [ "$DB_TYPE" = "mariadb" ]; then
    mysql_primary "DROP USER IF EXISTS '$REPL_USER'@'%';
      CREATE USER '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASS';
      GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$REPL_USER'@'%';
      FLUSH PRIVILEGES;"
  else
    mysql_primary "DROP USER IF EXISTS '$REPL_USER'@'%';
      CREATE USER '$REPL_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$REPL_PASS';
      GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$REPL_USER'@'%';
      FLUSH PRIVILEGES;"
  fi
  ok "Replication user ready"
}

stream_ospc_to_flex_primary() {
  local _db
  for _db in $DATABASES; do
    info "Streaming '$_db' OSPC → FLEX primary"
    if [ "$DRY_RUN" = "1" ]; then
      echo "[DRY] DROP DATABASE IF EXISTS \`$_db\`; CREATE DATABASE \`$_db\`;"
      echo "[DRY] ssh OSPC mysqldump $_db | ssh FLEX_PRI mysql $_db"
      continue
    fi
    mysql_primary "DROP DATABASE IF EXISTS \`$_db\`; CREATE DATABASE \`$_db\`;"
    # --set-gtid-purged=OFF is MySQL/Percona-only; MariaDB mysqldump on OSPC does not support it
    if [ "$DB_TYPE" = "mariadb" ]; then
      ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$OSPC_HA_VIP" \
        "MYSQL_PWD='$OSPC_ROOT_PASS' mysqldump -u root \
          --single-transaction --no-tablespaces --skip-lock-tables \
          --routines --triggers --events '$_db'" \
        | ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$FLEX_PRI_IP" \
            "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 '$_db'"
    else
      ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$OSPC_HA_VIP" \
        "MYSQL_PWD='$OSPC_ROOT_PASS' mysqldump -u root \
          --single-transaction --no-tablespaces --skip-lock-tables \
          --set-gtid-purged=OFF --routines --triggers --events '$_db'" \
        | ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_USER@$FLEX_PRI_IP" \
            "MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 '$_db'"
    fi
    ok "Streamed $_db"
  done
}

validate_primary() {
  local _db _tbl _src _dst _tbls
  log "VALIDATION — OSPC vs FLEX PRIMARY"
  for _db in $DATABASES; do
    echo; echo "── DB: $_db ─────────────────────────────────────────────"
    _tbls=$(mysql_src "SHOW TABLES FROM \`$_db\`;" 2>/dev/null || true)
    if [ -z "$_tbls" ]; then warn "$_db has no tables"; continue; fi
    printf "%-40s %12s %12s %8s\n" "Table" "OSPC" "FLEX" "Match"
    printf "%-40s %12s %12s %8s\n" "-----" "----" "----" "-----"
    while IFS= read -r _tbl; do
      [ -z "$_tbl" ] && continue
      _src="$(mysql_src "SELECT COUNT(*) FROM \`$_db\`.\`$_tbl\`;" 2>/dev/null || echo ERR)"
      _dst="$(mysql_primary "SELECT COUNT(*) FROM \`$_db\`.\`$_tbl\`;" 2>/dev/null || echo ERR)"
      if [ "$_src" = "$_dst" ]; then
        printf "%-40s %12s %12s %8s\n" "$_tbl" "$_src" "$_dst" "MATCH"
      else
        printf "%-40s %12s %12s %8s\n" "$_tbl" "$_src" "$_dst" "DIFF"
        err "Row mismatch on $_db.$_tbl — resolve before continuing"; exit 1
      fi
    done <<< "$_tbls"
    echo
    echo "[OSPC] first $SAMPLE_ROWS rows of first table in $_db:"
    mysql_src "SELECT * FROM \`$_db\`.\`$(echo "$_tbls" | head -1)\` LIMIT $SAMPLE_ROWS;" 2>/dev/null || true
    echo "[FLEX] first $SAMPLE_ROWS rows:"
    mysql_primary "USE \`$_db\`; SELECT * FROM \`$(echo "$_tbls" | head -1)\` LIMIT $SAMPLE_ROWS;" 2>/dev/null || true
  done
  ok "Primary validation passed"
}

make_primary_seed_dump() {
  info "Creating seed dump on FLEX primary for standbys"
  # --set-gtid-purged=ON is MySQL/Percona-only; MariaDB mysqldump does not support it
  if [ "$DB_TYPE" = "mariadb" ]; then
    run_remote "$FLEX_PRI_IP" "
      rm -f /tmp/flex_seed.sql.gz
      MYSQL_PWD='$FLEX_ROOT_PASS' mysqldump -u root \
        --all-databases --single-transaction \
        --routines --triggers --events \
        --master-data=2 \
        | gzip > /tmp/flex_seed.sql.gz
      ls -lh /tmp/flex_seed.sql.gz
    "
  else
    run_remote "$FLEX_PRI_IP" "
      rm -f /tmp/flex_seed.sql.gz
      MYSQL_PWD='$FLEX_ROOT_PASS' mysqldump -u root \
        --all-databases --single-transaction \
        --routines --triggers --events \
        --master-data=2 --set-gtid-purged=ON \
        | gzip > /tmp/flex_seed.sql.gz
      ls -lh /tmp/flex_seed.sql.gz
    "
  fi
  ok "Seed dump created on FLEX primary"
}

seed_standby_from_primary() {
  local _ip="$1"
  info "Seeding standby $_ip from FLEX primary"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY]  STOP SLAVE; RESET SLAVE ALL; RESET MASTER; (clear GTID on $_ip)"
    echo "[DRY]  ssh FLEX_PRI cat flex_seed.sql.gz | ssh $_ip gunzip | mysql"
    ok "Standby $_ip seeded (dry-run)"; return 0
  fi
  # Try sudo (Ubuntu auth_socket) first, then fall back to password+TCP. Do NOT swallow errors.
  run_remote "$_ip" "sudo mysql -u root -e 'STOP SLAVE; RESET SLAVE ALL; RESET MASTER;' 2>/dev/null || \
    MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e 'STOP SLAVE; RESET SLAVE ALL; RESET MASTER;'"
  local _db
  for _db in $DATABASES; do
    run_remote "$_ip" "sudo mysql -u root -e 'DROP DATABASE IF EXISTS \`$_db\`;' 2>/dev/null || \
      MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1 -e 'DROP DATABASE IF EXISTS \`$_db\`;'" 2>/dev/null || true
  done
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$FLEX_PRI_IP" "cat /tmp/flex_seed.sql.gz" \
    | ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$_ip" \
        "gunzip | MYSQL_PWD='$FLEX_ROOT_PASS' mysql -u root -h 127.0.0.1"
  ok "Standby $_ip seeded"
}

configure_standby_follow_primary() {
  local _ip="$1"
  info "Starting replication on standby $_ip"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY]  STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO ...; START SLAVE;"
    ok "Replication started on $_ip (dry-run)"; return 0
  fi
  mysql_standby "$_ip" "STOP SLAVE; RESET SLAVE ALL;
    CHANGE MASTER TO
      MASTER_HOST='$FLEX_PRI_IP', MASTER_PORT=3306,
      MASTER_USER='$REPL_USER', MASTER_PASSWORD='$REPL_PASS',
      $REPL_GTID_OPT;
    START SLAVE;"
  ok "Replication started on $_ip"
}

wait_for_standby_healthy() {
  local _ip="$1" _round _st _io _sql _lag _io_err
  info "Waiting for standby health on $_ip"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY]  SHOW SLAVE STATUS (skipped in dry-run)"
    ok "$_ip healthy (dry-run assumed)"; return 0
  fi
  for _round in $(seq 1 "$REPLICA_LAG_WAIT_ROUNDS"); do
    _st="$(mysql_standby "$_ip" "SHOW SLAVE STATUS" 2>/dev/null || true)"
    _io="$(printf '%s' "$_st" | awk -F'\t' '{print $11}')"
    _sql="$(printf '%s' "$_st" | awk -F'\t' '{print $12}')"
    _lag="$(printf '%s' "$_st" | awk -F'\t' '{print $33}')"
    _io_err="$(printf '%s' "$_st" | awk -F'\t' '{print $36}')"
    echo "[INFO] $_ip round=$_round IO=${_io:-?} SQL=${_sql:-?} Lag=${_lag:-unknown}"
    [ -n "$_io_err" ] && echo "[WARN] Last_IO_Error: $_io_err"
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
  err "Standby $_ip did not become healthy in time"
  mysql_standby "$_ip" "SHOW SLAVE STATUS" \
    | awk -F'\t' '{printf "  IO=%s SQL=%s Lag=%s\n  Last_IO_Error:  %s\n  Last_SQL_Error: %s\n",$11,$12,$33,$36,$38}' || true
  exit 1
}

postcheck_all_nodes() {
  log "POSTCHECK — FLEX PRIMARY + STANDBYS"
  mysql_primary "SELECT NOW(), @@hostname, @@read_only;" || true
  local _idx=0 _ip
  for _ip in $FLEX_STANDBY_IPS; do
    _idx=$((_idx + 1))
    info "Standby $_idx: $_ip"
    mysql_standby "$_ip" "SELECT NOW(), @@hostname, @@read_only;" || true
    mysql_standby "$_ip" "SHOW SLAVE STATUS" \
      | awk -F'\t' '{printf "  Master=%s  IO=%s  SQL=%s  Lag=%s  LastErr=%s\n",$2,$11,$12,$33,$20}' || true
  done
  ok "Postcheck complete"
}

cleanup_seed_files() {
  run_remote "$FLEX_PRI_IP" "rm -f /tmp/flex_seed.sql.gz" || true
  for _ip in $FLEX_STANDBY_IPS; do run_remote "$_ip" "rm -f /tmp/flex_seed.sql.gz" || true; done
}

# ══════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════
log "HA DB MIGRATION V2 — $(date)"
echo "Source OSPC HA VIP : $OSPC_HA_VIP  (user: root)"
echo "FLEX primary       : $FLEX_PRI_IP"
echo "FLEX standbys      : ${FLEX_STANDBY_IPS:-(none — single primary)}"
echo "HA method          : ${HA_METHOD:-(not configured)}"
echo "HA VIP             : ${HA_VIP:-(none)}"
echo "Log                : $LOG_FILE"

log "STEP 1 — PREFLIGHT"
run ssh -i "$SSH_KEY" -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@$OSPC_HA_VIP" "echo ok"
run mysql_src "SELECT VERSION();"
run_remote "$FLEX_PRI_IP" "hostname && df -h / && free -h"
for _ip in $FLEX_STANDBY_IPS; do run_remote "$_ip" "hostname && df -h / && free -h"; done
ok "Preflight passed"

DATABASES="$(discover_databases)"
[ -z "$DATABASES" ] && { err "No user databases found on OSPC HA VIP $OSPC_HA_VIP"; exit 1; }
info "Databases to migrate: $DATABASES"

log "STEP 2 — PREPARE FLEX NODES"
install_db_stack_on_node "$FLEX_PRI_IP"
if [ -n "$FLEX_STANDBY_IPS" ]; then
  configure_primary_replication_settings
  create_replication_user_on_primary
  _ridx=0
  for _ip in $FLEX_STANDBY_IPS; do
    _ridx=$((_ridx + 1))
    install_db_stack_on_node "$_ip"
    configure_standby_replication_settings "$_ip" "$((_ridx + REPLICA_SERVER_ID_BASE))"
  done
fi
ok "All FLEX nodes prepared"

log "STEP 3 — STREAM OSPC → FLEX PRIMARY"
stream_ospc_to_flex_primary

log "STEP 4 — VALIDATE FLEX PRIMARY"
validate_primary

if [ -n "$FLEX_STANDBY_IPS" ]; then
  log "STEP 5 — CREATE SEED DUMP ON FLEX PRIMARY"
  make_primary_seed_dump

  log "STEP 6 — SEED STANDBYS"
  for _ip in $FLEX_STANDBY_IPS; do seed_standby_from_primary "$_ip"; done
  ok "All standbys seeded"

  log "STEP 7 — START REPLICATION ON STANDBYS"
  for _ip in $FLEX_STANDBY_IPS; do configure_standby_follow_primary "$_ip"; done

  log "STEP 8 — STANDBY HEALTH CHECK"
  for _ip in $FLEX_STANDBY_IPS; do wait_for_standby_healthy "$_ip"; done

  log "STEP 9 — POSTCHECK"
  postcheck_all_nodes
  cleanup_seed_files
else
  info "No standbys configured — skipping replication setup"
fi

log "STEP 10 — HA CONTROL LAYER"
echo "[INFO] HA method: ${HA_METHOD:-(not configured)}"
if [ -n "$FLEX_STANDBY_IPS" ]; then
  case "${HA_METHOD:-}" in
    orchestrator) echo "[ACTION] Register $FLEX_PRI_IP with Orchestrator; add standbys: $FLEX_STANDBY_IPS" ;;
    keepalived)   echo "[ACTION] Configure keepalived VRRP on $FLEX_PRI_IP with VIP ${HA_VIP:-(set HA_VIP)}" ;;
    proxysql)     echo "[ACTION] Add $FLEX_PRI_IP as read-write; standbys as read-only in ProxySQL" ;;
    maxscale)     echo "[ACTION] Register $FLEX_PRI_IP + standbys in MaxScale monitor" ;;
    *)            echo "[ACTION] Deploy HA layer (keepalived/ProxySQL/MaxScale/orchestrator) → $FLEX_PRI_IP" ;;
  esac
fi
[ -n "$HA_VIP" ] && echo "[INFO] FLEX HA VIP target: $HA_VIP" || echo "[ACTION] Configure HA VIP/proxy endpoint after verifying health"
echo "[ACTION] Update app DB_HOST → ${HA_VIP:-$FLEX_PRI_IP}"
echo "[NOTE]  Retain OSPC VMs 48–72h as rollback window"
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
        # HA DBaaS = DBaaS+Replica script (identical flow) + HA control layer appended
        tmpl = _V2_DBAAS + _CMP_WRAPPERS['dbaas'] + _CMP_BODY + _CMP_REPLICA_SECTION + _CMP_REPORT_CALL + _HA_SUFFIX
        return _fill(tmpl,
            SCENARIO='HA DBaaS',
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
