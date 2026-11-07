#!/bin/bash
# S5 - Observability: snapshot stats CSV/HTML/Prometheus, then a "hung node" (docker pause odoo-3: process frozen,
# TCP still accepted by the kernel) and its recovery, recorded from the runtime API (timeline), the logs and the metrics.
source "$(dirname "$0")/lib.sh"
N=s5_$TS; OUT=$RAW/$N
"$LAB/scenarios/reset_lab.sh" | tail -1
AUTH="$HAPROXY_STATS_USER:$HAPROXY_STATS_PASSWORD"
hap "show stat" > ${OUT}_stats_before.csv
curl -sS -u "$AUTH" "http://lb01:8404/stats" > ${OUT}_stats_page.html
curl -sS -u "$AUTH" "http://lb01:8404/stats;csv" > ${OUT}_stats_http.csv
curl -sS "http://lb01:8404/metrics" | grep -E '^haproxy_server_(status|check_status|up)\{' | grep be_odoo > ${OUT}_metrics_before.txt || true
log "S5: freeze odoo-3 (docker pause) and record the state machine every 0.5 s"
echo "t_ms,status,check_status,check_duration,lastchg_s" > ${OUT}_timeline.csv
poll(){ hap "show stat" | awk -F, -v t=$(( $(now_ms) - T0 )) '$1=="be_odoo" && $2=="odoo3" {print t","$18","$37","$38","$24}' >> ${OUT}_timeline.csv; }
T0=$(now_ms); app "sudo docker pause odoo-3 >/dev/null"
until grep -q ',DOWN,' ${OUT}_timeline.csv; do poll; sleep 0.5; (( $(now_ms) - T0 > 60000 )) && break; done
DET=$(grep -m1 ',DOWN,' ${OUT}_timeline.csv | cut -d, -f1)
DOWNSNAP=$(hap "show stat" | awk -F, '$1 ~ /be_odoo/ && $2 ~ /odoo/ {print $1"/"$2, $18, $37}')
curl -sS "http://lb01:8404/metrics" | grep -E '^haproxy_server_(status|check_status|up)\{' | grep be_odoo > ${OUT}_metrics_down.txt || true
log "odoo3 DOWN after $DET ms (hang = health checks time out). Unpause."
T1=$(now_ms); app "sudo docker unpause odoo-3 >/dev/null"
until [ "$(tail -1 ${OUT}_timeline.csv | cut -d, -f2)" = UP ]; do poll; sleep 0.5; (( $(now_ms) - T0 > 120000 )) && break; done
REC=$(( $(now_ms) - T1 ))
log "odoo3 UP again $REC ms after unpause"
lbx "sudo journalctl -u haproxy --since @$(( T0/1000 - 1 )) -o short-iso-precise | grep -v WARNING | grep -E 'Server be_odoo(_ws)?/odoo3 is'" > ${OUT}_haproxy_transitions.log || true
hap "show stat" > ${OUT}_stats_after.csv
SEQ=$(cut -d, -f2,3 ${OUT}_timeline.csv | tail -n +2 | uniq | tr '\n' ' ')
NLOG=$(wc -l < ${OUT}_haproxy_transitions.log)
PASS=PASS; [ -n "$DET" ] && grep -q ',DOWN,' ${OUT}_timeline.csv && (( NLOG >= 2 )) && grep -q 'odoo3' ${OUT}_metrics_down.txt || PASS=FAIL
printf "S5\t%s\thang(docker pause)\tdetect_ms=%s\trecovery_ms=%s\tlog_transitions=%s\tstates=%s\t%s\n" "$TS" "$DET" "$REC" "$NLOG" "$(echo $SEQ | tr ' ' '|')" "$PASS" >> "$RAW/results.tsv"
echo "--- while DOWN:"; echo "$DOWNSNAP"; echo "--- log:"; cut -c1-200 ${OUT}_haproxy_transitions.log
echo "VERDICT S5 $PASS: hung node detected DOWN in $DET ms, back UP $REC ms after unpause; state sequence: $SEQ; $NLOG log transitions; stats CSV/HTML + Prometheus captured"
