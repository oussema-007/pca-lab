#!/bin/bash
# S6 (phase 6) - Database tier: replication lag (RPO) and manual promotion of the streaming replica (RTO).
#  1. measure replication lag under a steady write load (separate database rpo_test, Odoo data untouched)
#  2. crash the primary (docker kill pca-db) -> compare last acknowledged write vs last replicated row (= RPO)
#  3. promote the replica (pg_promote) and give it the DNS name "db" on the Docker network -> Odoo reconnects (= RTO)
#  4. restore: discard the promoted replica, restart the original primary, rebuild a fresh replica
# Note: Odoo writes made during the failover window (logs, sessions) are discarded at step 4 (lab only).
source "$(dirname "$0")/lib.sh"
N=s6_$TS; OUT=$RAW/$N
NET=pca-odoo_backend
psqlp(){ app "sudo docker exec -i pca-db psql -U odoo -tAq $*"; }
psqlr(){ app "sudo docker exec -i pca-db-replica psql -U odoo -tAq $*"; }
"$LAB/scenarios/reset_lab.sh" | tail -1
[ "$(container_healthy pca-db-replica)" = healthy ] || { echo "replica not healthy"; exit 1; }
STATE=$(psqlp -d postgres -c "\"select state from pg_stat_replication where application_name<>'' limit 1\"")
log "replication state on primary: $STATE"
[ "$STATE" = streaming ] || { echo "replica not streaming"; exit 1; }
psqlp -d postgres -c "\"select 1 from pg_database where datname='rpo_test'\"" | grep -q 1 || psqlp -d postgres -c "\"create database rpo_test\""
psqlp -d rpo_test -c "\"create table if not exists t(id bigserial primary key, ts timestamptz not null default clock_timestamp())\""
log "1) steady write load: 1 insert every ~20 ms on the primary, sampling replication lag"
# writer inside the primary container: prints every acknowledged id with its commit timestamp
app "sudo docker exec pca-db bash -c 'while true; do psql -U odoo -d rpo_test -tAqc \"insert into t default values returning id, extract(epoch from ts)*1000\" || exit 0; sleep 0.02; done'" > ${OUT}_writer_acks.txt 2>/dev/null & W=$!
python3 -I "$LAB/scenarios/probe.py" --duration 400 --out ${OUT}_probe.csv 2>${OUT}_probe.log & P=$!
echo "t,write_lag,flush_lag,replay_lag,lag_bytes" > ${OUT}_lag.csv
for i in $(seq 1 20); do
  psqlp -d postgres -F, -c "\"select to_char(now(),'HH24:MI:SS'), coalesce(write_lag::text,'0'), coalesce(flush_lag::text,'0'), coalesce(replay_lag::text,'0'), pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) from pg_stat_replication\"" >> ${OUT}_lag.csv
  sleep 0.5
done
LAGMAX=$(python3 -I -c '
import csv,sys
def ms(v):
    if v in ("0",""): return 0.0
    h,m,s=v.split(":"); return (int(h)*3600+int(m)*60+float(s))*1000
r=list(csv.DictReader(open(sys.argv[1])))
print("%.2f %.2f %d" % (max(ms(x["replay_lag"]) for x in r), sum(ms(x["replay_lag"]) for x in r)/len(r), max(int(float(x["lag_bytes"])) for x in r)))' ${OUT}_lag.csv)
read -r LAG_MAX_MS LAG_AVG_MS LAG_MAX_BYTES <<< "$LAGMAX"
log "replay lag over 10 s: max ${LAG_MAX_MS} ms, avg ${LAG_AVG_MS} ms, max ${LAG_MAX_BYTES} bytes behind"
log "2) crash the primary (docker kill pca-db)"
T0=$(now_ms); app "sudo docker kill pca-db >/dev/null"
sleep 1; kill $W 2>/dev/null || true; wait $W 2>/dev/null || true
ACK_LAST=$(grep -E '^[0-9]+\|' ${OUT}_writer_acks.txt | tail -1)
ACK_ID=${ACK_LAST%%|*}; ACK_TS=${ACK_LAST##*|}
REP_LAST=$(psqlr -d rpo_test -c "\"select id, extract(epoch from ts)*1000 from t order by id desc limit 1\"")
REP_ID=${REP_LAST%%|*}
LOST=$(( ACK_ID - REP_ID )); [ $LOST -lt 0 ] && LOST=0
RPO_MS=$(python3 -I -c "print(max(0, round(float('$ACK_TS') - float('${REP_LAST##*|}'), 1)))")
log "last acknowledged write id=$ACK_ID, last row on replica id=$REP_ID -> lost $LOST committed rows (RPO = ${RPO_MS} ms of writes)"
log "3) manual promotion + DNS switch"
T1=$(now_ms)
psqlr -d postgres -c "\"select pg_promote(true, 30)\"" >/dev/null
until [ "$(psqlr -d postgres -c "\"select pg_is_in_recovery()\"")" = f ]; do sleep 0.2; done
T_PROM=$(( $(now_ms) - T1 ))
app "sudo docker network disconnect $NET pca-db-replica && sudo docker network connect --alias db $NET pca-db-replica"
T_SW=$(( $(now_ms) - T0 ))
psqlr -d rpo_test -c "\"insert into t default values\"" && WRITABLE=yes || WRITABLE=no
log "replica promoted in ${T_PROM} ms, writable=$WRITABLE, now answers as 'db' ($T_SW ms after the crash)"
# wait until the user probe is OK again
until tail -1 ${OUT}_probe.csv | grep -q ',1,$'; do sleep 0.2; (( $(now_ms) - T0 > 180000 )) && break; done
T_APP=$(( $(now_ms) - T0 ))
log "Odoo answering again through the LB $T_APP ms after the crash"
sleep 10; kill $P 2>/dev/null; wait $P 2>/dev/null || true
PS_JSON=$(python3 -I "$LAB/scenarios/probe_summary.py" ${OUT}_probe.csv)
GAP=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["max_gap_ms"])' "$PS_JSON")
PF=$(python3 -I -c 'import json,sys; p=json.loads(sys.argv[1]); print("%d/%d" % (p["failed"],p["total"]))' "$PS_JSON")
log "4) restore the original topology"
app "sudo docker rm -f pca-db-replica >/dev/null && sudo docker volume rm pca-odoo_pg-replica >/dev/null && sudo docker start pca-db >/dev/null"
for i in $(seq 1 60); do [ "$(container_healthy pca-db)" = healthy ] && break; sleep 1; done
app "cd /opt/pca-odoo && sudo docker compose restart odoo-1 odoo-2 odoo-3 >/dev/null 2>&1 && sudo docker compose up -d db-replica 2>&1 | tail -1" >/dev/null
for i in $(seq 1 120); do [ "$(container_healthy pca-db-replica)" = healthy ] && break; sleep 1; done
"$LAB/scenarios/reset_lab.sh" | tail -1
STATE2=$(psqlp -d postgres -c "\"select state from pg_stat_replication limit 1\"")
log "after restore: replica $STATE2"
PASS=PASS; [ "$WRITABLE" = yes ] && [ "$STATE2" = streaming ] || PASS=FAIL
python3 -I -c 'import json,sys; print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2])), indent=1))' scenario S6 ts "$TS" replay_lag_max_ms "$LAG_MAX_MS" replay_lag_avg_ms "$LAG_AVG_MS" lag_max_bytes "$LAG_MAX_BYTES" ack_last_id "$ACK_ID" replica_last_id "$REP_ID" lost_rows "$LOST" rpo_ms "$RPO_MS" promote_ms "$T_PROM" crash_to_db_switched_ms "$T_SW" crash_to_odoo_ok_ms "$T_APP" probe_failed "$PF" probe_max_gap_ms "$GAP" replica_after_restore "$STATE2" > ${OUT}_result.json
printf "S6\t%s\tdb-failover\treplay_lag_max_ms=%s\tlag_avg_ms=%s\tlost_rows=%s\trpo_ms=%s\tpromote_ms=%s\tcrash_to_db_ms=%s\tcrash_to_odoo_ok_ms=%s\tprobe_failed=%s\tafter_restore=%s\t%s\n" "$TS" "$LAG_MAX_MS" "$LAG_AVG_MS" "$LOST" "$RPO_MS" "$T_PROM" "$T_SW" "$T_APP" "$PF" "$STATE2" "$PASS" >> "$RAW/results.tsv"
echo "VERDICT S6 $PASS: replication lag max ${LAG_MAX_MS} ms (avg ${LAG_AVG_MS}); primary crash -> lost ${LOST} committed rows (RPO ${RPO_MS} ms); promotion ${T_PROM} ms; Odoo back ${T_APP} ms after crash (manual); probe failed ${PF}; replica after restore: ${STATE2}"
