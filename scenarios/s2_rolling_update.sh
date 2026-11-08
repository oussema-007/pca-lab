#!/bin/bash
# S2 - Rolling update without downtime. Under light load (k6 5 VUs + user probe), for each node in turn:
# drain (no new users, existing sessions finish) -> 0 current sessions -> maint -> recreate the container
# -> wait healthy -> ready -> wait HAProxy UP. Pass: 0 failed requests during the whole window.
source "$(dirname "$0")/lib.sh"
N=s2_$TS; OUT=$RAW/$N
"$LAB/scenarios/reset_lab.sh" | tail -1
log "S2: start probe + k6 (5 VUs)"
python3 -I "$LAB/scenarios/probe.py" --duration 900 --out ${OUT}_probe.csv 2>${OUT}_probe.log & P1=$!
k6run $N 5 900s 0.5 > ${OUT}_k6.txt 2>&1 & P2=$!
sleep 15
scur(){ srv_field be_odoo "$1" 5; }
wait_idle(){ local s=$1 to=$2 t0 z=0; t0=$(now_ms)
  while (( $(now_ms) - t0 < to*1000 )); do [ "$(scur $s)" = 0 ] && z=$((z+1)) || z=0; (( z >= 2 )) && break; sleep 0.25; done
  echo $(( $(now_ms) - t0 )); }
echo -e "node\tdrain_to_idle_ms\trecreate_to_healthy_ms\tready_to_UP_ms\tnode_total_ms\told_container\tnew_container" > ${OUT}_steps.tsv
TSTART=$(now_ms)
for n in 1 2 3; do
  s=odoo$n; c=odoo-$n; t0=$(now_ms)
  OLD=$(app "sudo docker inspect -f '{{.Id}}' $c" | cut -c1-12)
  log "[$s] drain"; for b in be_odoo be_odoo_ws; do hap "set server $b/$s state drain" >/dev/null; done
  D=$(wait_idle $s 30)
  log "[$s] idle after $D ms -> maint"; for b in be_odoo be_odoo_ws; do hap "set server $b/$s state maint" >/dev/null; done
  wait_idle $s 10 >/dev/null
  log "[$s] recreate container $c (simulated update)"; t1=$(now_ms)
  app "cd /opt/pca-odoo && sudo docker compose up -d --no-deps --force-recreate $c 2>&1 | tail -1" >/dev/null
  H=$(wait_healthy $c 240); NEW=$(app "sudo docker inspect -f '{{.Id}}' $c" | cut -c1-12)
  warm_node $n
  log "[$s] healthy after $H ms (container $OLD -> $NEW), warmed up -> ready"
  for b in be_odoo be_odoo_ws; do hap "set server $b/$s state ready" >/dev/null; done
  U=$(wait_status be_odoo $s '^UP$' 120); wait_status be_odoo_ws $s '^UP$' 120 >/dev/null
  log "[$s] UP in HAProxy after $U ms"
  echo -e "$s\t$D\t$H\t$U\t$(( $(now_ms) - t0 ))\t$OLD\t$NEW" >> ${OUT}_steps.tsv
  sleep 5
done
TOTAL=$(( $(now_ms) - TSTART ))
sleep 10
kill -INT $P2 2>/dev/null; kill $P1 2>/dev/null; wait $P2 2>/dev/null || true; wait $P1 2>/dev/null || true
PS_JSON=$(python3 -I "$LAB/scenarios/probe_summary.py" ${OUT}_probe.csv)
read -r REQS RPS P95 FRATE FCOUNT RPCERR < <(k6json $RAW/${N}_k6.json)
PF=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["failed"])' "$PS_JSON")
PT=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["total"])' "$PS_JSON")
GAP=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["max_gap_ms"])' "$PS_JSON")
TRANS=$(python3 -I -c 'import json,sys; print("->".join(s for _,s in json.loads(sys.argv[1])["server_transitions"]))' "$PS_JSON")
PASS=PASS; (( PF == 0 && FCOUNT == 0 && RPCERR == 0 )) || PASS=FAIL
python3 -I -c 'import json,sys; print(json.dumps({"scenario":"S2","ts":sys.argv[1],"window_ms":int(sys.argv[2]),"probe":json.loads(sys.argv[3]),"k6":{"reqs":int(sys.argv[4]),"rps":float(sys.argv[5]),"p95_ms":float(sys.argv[6]),"failed":int(sys.argv[7]),"rpc_errors":int(sys.argv[8])},"steps":open(sys.argv[9]).read().splitlines()},indent=1))' \
  "$TS" "$TOTAL" "$PS_JSON" "$REQS" "$RPS" "$P95" "$FCOUNT" "$RPCERR" ${OUT}_steps.tsv > ${OUT}_result.json
printf "S2\t%s\trolling\twindow_ms=%s\tk6_reqs=%s\tk6_failed=%s\trpc_errors=%s\tprobe=%s/%s_failed\tprobe_max_gap_ms=%s\tk6_p95=%s\tservers=%s\t%s\n" "$TS" "$TOTAL" "$REQS" "$FCOUNT" "$RPCERR" "$PF" "$PT" "$GAP" "$P95" "$TRANS" "$PASS" >> "$RAW/results.tsv"
column -t ${OUT}_steps.tsv
echo "VERDICT S2 $PASS: 3 nodes replaced one by one in $((TOTAL/1000)) s; k6 ${REQS} requests, ${FCOUNT} failed, ${RPCERR} RPC errors; user probe ${PF}/${PT} failed, max gap ${GAP} ms, path ${TRANS}"
