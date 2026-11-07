#!/bin/bash
# S3 - Scale-out: identical closed-loop k6 profile, first with only odoo1 in service (odoo2/3 in maint), then with 3 nodes.
# Reports req/s, p95, error rate, per-server request split, app01 CPU (2 vCPU) and kali CPU (load generator) during each run.
# CPU_PER_NODE=0.66 caps each Odoo container (docker update, reverted at the end) to emulate 3 independent small nodes
# instead of 3 containers sharing the same 2 vCPU. Default: no cap (= the real lab).
source "$(dirname "$0")/lib.sh"
VUS=${VUS:-12}; DUR=${DUR:-60s}; THINK=${THINK:-0}; CPU_PER_NODE=${CPU_PER_NODE:-}
VARIANT=${CPU_PER_NODE:+capped${CPU_PER_NODE}cpu}; VARIANT=${VARIANT:-shared}
N=s3_${VARIANT}_$TS; OUT=$RAW/$N
restore_cpu(){ app "sudo docker update --cpus 2 odoo-1 odoo-2 odoo-3 >/dev/null"; }
trap restore_cpu EXIT
cpu_sample(){ app "head -1 /proc/stat"; }
cpu_busy(){ python3 -I -c 'import sys
a=list(map(int,sys.argv[1].split()[1:])); b=list(map(int,sys.argv[2].split()[1:]))
d=[y-x for x,y in zip(a,b)]; idle=d[3]+d[4]; print(round(100*(sum(d)-idle)/sum(d),1))' "$1" "$2"; }
stot(){ hap "show stat" | awk -F, '$1=="be_odoo" && $2 ~ /^odoo/ {printf "%s=%s ", $2, $8}'; }
run(){ local label=$1
  hap "clear counters all" >/dev/null
  local c0; c0=$(cpu_sample); local k0; k0=$(head -1 /proc/stat)
  k6run ${N}_$label $VUS $DUR $THINK > ${OUT}_${label}_k6.txt 2>&1 || true
  local c1; c1=$(cpu_sample); local k1; k1=$(head -1 /proc/stat)
  local busy; busy=$(cpu_busy "$c0" "$c1"); local kbusy; kbusy=$(cpu_busy "$k0" "$k1")
  read -r REQS RPS P95 FRATE FCOUNT RPCERR < <(k6json $RAW/${N}_${label}_k6.json)
  local split; split=$(stot)
  local OKRPS; OKRPS=$(python3 -I -c "import json,sys; d=json.load(open(sys.argv[1]))['state']['testRunDurationMs']; print(round(($REQS-$FCOUNT)/(d/1000),1))" $RAW/${N}_${label}_k6.json)
  echo "$label ok_rps=$OKRPS rps=$RPS p95_ms=$P95 reqs=$REQS failed=$FCOUNT rpc_errors=$RPCERR app01_cpu_busy=${busy}% kali_cpu_busy=${kbusy}% split: $split" | tee -a ${OUT}_summary.txt
  eval "R_${label}_OK=$OKRPS; R_${label}_RPS=$RPS; R_${label}_P95=$P95; R_${label}_ERR=$FRATE; R_${label}_CPU=$busy"
}
"$LAB/scenarios/reset_lab.sh" | tail -1
app "echo nproc=\$(nproc); free -m | head -2" | tee ${OUT}_host.txt
if [ -n "$CPU_PER_NODE" ]; then app "sudo docker update --cpus $CPU_PER_NODE odoo-1 odoo-2 odoo-3 >/dev/null"; log "variant: each Odoo container capped to $CPU_PER_NODE vCPU"; fi
app "sudo docker inspect -f '{{.Name}} NanoCpus={{.HostConfig.NanoCpus}}' odoo-1 odoo-2 odoo-3" >> ${OUT}_host.txt
log "S3 run A: only odoo1 in service (odoo2, odoo3 -> maint), $VUS VUs, think ${THINK}s, $DUR"
for s in odoo2 odoo3; do for b in be_odoo be_odoo_ws; do hap "set server $b/$s state maint" >/dev/null; done; done
sleep 3; k6run warmup_$TS 4 15s 0 >/dev/null 2>&1 || true
run 1node
app "top -b -n1 -o %CPU | head -15" > ${OUT}_1node_top.txt
log "S3 run B: all 3 nodes"
for s in odoo2 odoo3; do for b in be_odoo be_odoo_ws; do hap "set server $b/$s state ready" >/dev/null; done; done
for s in odoo2 odoo3; do wait_status be_odoo $s '^UP$' 60 >/dev/null; done
sleep 3; k6run warmup_$TS 4 15s 0 >/dev/null 2>&1 || true
run 3nodes
app "top -b -n1 -o %CPU | head -15" > ${OUT}_3nodes_top.txt
GAIN=$(python3 -I -c "print(round($R_3nodes_OK/max($R_1node_OK,0.1),2))")
P95R=$(python3 -I -c "print(round($R_3nodes_P95/$R_1node_P95,2))")
printf "S3\t%s\t%s\tVUs=%s,think=%s,%s\t1node_ok_rps=%s\t1node_rps=%s\t1node_p95=%s\t1node_err=%s\t1node_cpu=%s%%\t3nodes_ok_rps=%s\t3nodes_rps=%s\t3nodes_p95=%s\t3nodes_err=%s\t3nodes_cpu=%s%%\tgain=x%s\tp95_ratio=%s\n" \
  "$TS" "$VARIANT" "$VUS" "$THINK" "$DUR" "$R_1node_OK" "$R_1node_RPS" "$R_1node_P95" "$R_1node_ERR" "$R_1node_CPU" "$R_3nodes_OK" "$R_3nodes_RPS" "$R_3nodes_P95" "$R_3nodes_ERR" "$R_3nodes_CPU" "$GAIN" "$P95R" >> "$RAW/results.tsv"
echo "VERDICT S3[$VARIANT] DONE: 1 node ${R_1node_OK} successful req/s (raw ${R_1node_RPS}, error rate ${R_1node_ERR}) p95 ${R_1node_P95} ms (app01 CPU ${R_1node_CPU}%) -> 3 nodes ${R_3nodes_OK} successful req/s (error rate ${R_3nodes_ERR}) p95 ${R_3nodes_P95} ms (CPU ${R_3nodes_CPU}%): successful throughput x${GAIN}, p95 x${P95R} (app01 has $(app nproc) vCPU)"
