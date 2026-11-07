#!/bin/bash
# S1 - Node failure: a user probe (1 authenticated call / 200 ms, pinned to odoo1) + light k6 load,
# then odoo-1 is stopped (MODE=stop: docker stop, graceful) or crashed (MODE=kill: SIGKILL), kept down 25 s, restarted.
# Measures: HAProxy detection time, user-visible failures, longest user gap, session continuity, recovery time.
source "$(dirname "$0")/lib.sh"
MODE=${MODE:-stop}
# PROBE_ARGS=--close makes the probe send "Connection: close" (non-browser client), see DECISIONS.md
N=s1_${MODE}_$TS; OUT=$RAW/$N
"$LAB/scenarios/reset_lab.sh" | tail -1
log "S1 ($MODE): probe pinned on odoo1 + k6 5 VUs"
python3 -I "$LAB/scenarios/probe.py" --duration 95 --pin odoo1 ${PROBE_ARGS:-} --out ${OUT}_probe.csv 2>${OUT}_probe.log & P1=$!
k6run $N 5 90s 0.5 > ${OUT}_k6.txt 2>&1 & P2=$!
sleep 20
T0=$(now_ms); log "T0: docker $MODE odoo-1"
app "sudo docker $MODE odoo-1 >/dev/null" & PS=$!
DETECT=$(wait_status be_odoo odoo1 '^DOWN' 60); TD=$(now_ms)
wait $PS; TSTOP=$(( $(now_ms) - T0 ))
log "HAProxy marked be_odoo/odoo1 DOWN after ${DETECT} ms (docker $MODE returned after <= ${TSTOP} ms)"
STAT_DOWN=$(hap "show stat" | awk -F, '$1=="be_odoo" {print $2, $18, "stot="$8, "econ="$14, "eresp="$15, "retries="$16, "redispatch="$17}')
sleep 25
T2=$(now_ms); log "restart odoo-1"
app "sudo docker start odoo-1 >/dev/null"
HEALTHY=$(wait_healthy odoo-1 240); UPMS=$(wait_status be_odoo odoo1 '^UP$' 120)
RECOV=$(( $(now_ms) - T2 ))
log "odoo-1 container healthy after ${HEALTHY} ms, back in rotation (UP) $RECOV ms after start"
wait $P1 $P2 || true
# HAProxy's own view of the transitions (journald, microsecond timestamps)
lbx "sudo journalctl -u haproxy --since @$(( T0/1000 - 2 )) -o short-iso-precise | grep -E 'Server be_odoo(_ws)?/odoo1 is (DOWN|UP)'" > ${OUT}_haproxy_transitions.log || true
LOGDOWN=$(grep -m1 'be_odoo/odoo1 is DOWN' ${OUT}_haproxy_transitions.log | awk '{print $1}')
LOGDETECT=$(python3 -I -c 'import sys,datetime; t=sys.argv[1]; print(int(datetime.datetime.fromisoformat(t).timestamp()*1000)-int(sys.argv[2])) if t else print("n/a")' "$LOGDOWN" "$T0")
PS_JSON=$(python3 -I "$LAB/scenarios/probe_summary.py" ${OUT}_probe.csv)
read -r REQS RPS P95 FRATE FCOUNT RPCERR < <(k6json $RAW/${N}_k6.json)
SESSION_LOST=$(grep -c SessionExpired ${OUT}_probe.csv || true)
python3 -I - "$PS_JSON" <<PY > ${OUT}_result.json
import json,sys
p=json.loads(sys.argv[1])
print(json.dumps({"scenario":"S1","mode":"$MODE","ts":"$TS","detect_ms_poll":int("$DETECT") if "$DETECT".isdigit() else "$DETECT","detect_ms_haproxy_log":"$LOGDETECT",
 "docker_cmd_ms":$TSTOP,"recovery_container_healthy_ms":int("$HEALTHY" or 0),"recovery_back_in_lb_ms":$RECOV,
 "probe":p,"probe_session_expired":$SESSION_LOST,
 "k6":{"reqs":$REQS,"rps":$RPS,"p95_ms":$P95,"failed":$FCOUNT,"failed_rate":$FRATE,"rpc_errors":$RPCERR},
 "be_odoo_stats_while_down":"""$STAT_DOWN""".splitlines()},indent=1))
PY
FAILED_PCT=$(python3 -I -c 'import json,sys; p=json.loads(sys.argv[1]); print(p["failed_pct"])' "$PS_JSON")
MAXGAP=$(python3 -I -c 'import json,sys; p=json.loads(sys.argv[1]); print(p["max_gap_ms"])' "$PS_JSON")
TRANS=$(python3 -I -c 'import json,sys; p=json.loads(sys.argv[1]); print("->".join(s for _,s in p["server_transitions"]))' "$PS_JSON")
K6PCT=$(python3 -I -c "print(round(100*$FRATE,3))")
PASS=PASS
[[ "$DETECT" =~ ^[0-9]+$ ]] && (( DETECT <= 9000 )) || PASS=FAIL
python3 -I -c "import sys; sys.exit(0 if $FAILED_PCT<=1 and $K6PCT<=1 else 1)" || PASS=FAIL
(( SESSION_LOST == 0 )) || PASS=FAIL
printf "S1\t%s\t%s\tdetect_ms=%s\tdetect_log_ms=%s\tprobe_failed_pct=%s\tprobe_max_gap_ms=%s\tk6_failed=%s(%s%%)\tsession_lost=%s\trecovery_ms=%s\tservers=%s\t%s\n" \
  "$TS" "$MODE" "$DETECT" "$LOGDETECT" "$FAILED_PCT" "$MAXGAP" "$FCOUNT" "$K6PCT" "$SESSION_LOST" "$RECOV" "$TRANS" "$PASS" >> "$RAW/results.tsv"
echo "VERDICT S1[$MODE] $PASS: detection ${DETECT} ms (HAProxy log ${LOGDETECT} ms), user probe failed ${FAILED_PCT}% max gap ${MAXGAP} ms, k6 failed ${FCOUNT} (${K6PCT}%), session lost ${SESSION_LOST}x, path ${TRANS}, back in LB ${RECOV} ms after restart"
