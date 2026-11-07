#!/bin/bash
# S4 - Rate limiting at the edge: a burst from kali WITHOUT the exemption header must get 429 above the threshold,
# the backend must not see the excess, the exempt load-test client is not throttled, and normal browsing works afterwards.
source "$(dirname "$0")/lib.sh"
BURST=${BURST:-600}; PAR=${PAR:-20}
N=s4_$TS; OUT=$RAW/$N
LIMIT=$(lbx "sudo grep -oP 'sc_http_req_rate\(0\) gt \K[0-9]+' /etc/haproxy/haproxy.cfg")
"$LAB/scenarios/reset_lab.sh" | tail -1
B0=$(srv_field be_odoo BACKEND 8)
log "S4: burst of $BURST GET /web/login, $PAR in parallel, no exemption header (limit: $LIMIT req / 10 s / IP)"
T0=$(now_ms)
seq 1 $BURST | xargs -P $PAR -I{} curl -sS -o /dev/null -w '%{http_code}\n' $BASE/web/login > ${OUT}_burst_codes.txt
DT=$(( $(now_ms) - T0 ))
B1=$(srv_field be_odoo BACKEND 8)
TABLE=$(hap "show table fe_https" | grep -E "192.168.100.30|table:")
C200=$(grep -c '^200$' ${OUT}_burst_codes.txt || true); C429=$(grep -c '^429$' ${OUT}_burst_codes.txt || true)
FIRST429=$(grep -n '^429$' ${OUT}_burst_codes.txt | head -1 | cut -d: -f1 || true); FIRST429=${FIRST429:-none}
OTHER=$(grep -vcE '^(200|429)$' ${OUT}_burst_codes.txt || true)
log "burst done in $DT ms: 200=$C200 429=$C429 other=$OTHER, first 429 at response #$FIRST429; backend received $((B1-B0)) requests"
log "stick-table entry: $TABLE"
log "same burst size from the exempt test client (secret header): "
EX=$(seq 1 300 | xargs -P $PAR -I{} curl -sS -o /dev/null -w '%{http_code}\n' -H "$PCA_HDR_NAME: $PCA_HDR_VALUE" $BASE/web/login | sort | uniq -c | tr '\n' ' ')
log "   exempt 300 requests -> $EX"
WRONG=$(seq 1 150 | xargs -P 10 -I{} curl -sS -o /dev/null -w '%{http_code}\n' -H "$PCA_HDR_NAME: guessed-value" $BASE/web/login | sort | uniq -c | tr '\n' ' ')
log "   wrong header value, 150 requests (tracked like any client -> throttled above the limit) -> $WRONG"
log "wait 11 s for the 10 s window to slide, then browse normally (GET login page, POST login, open web client)"
sleep 11
J=$RAW/.s4.jar; P=$RAW/.s4.page; : > $J
A=$(curl -sS -c $J -b $J -o $P -w '%{http_code}' $BASE/web/login)
CSRF=$(grep -oP 'name="csrf_token" value="\K[^"]+' $P)
B=$(curl -sS -c $J -b $J -o /dev/null -w '%{http_code}' --data-urlencode "csrf_token=$CSRF" --data-urlencode login=vendeur1 --data-urlencode "password=$PCA_PW1" $BASE/web/login)
C=$(curl -sS -b $J -o /dev/null -w '%{http_code}' $BASE/web)
: > $J; : > $P   # do not keep session cookies on disk
log "after the burst: GET /web/login=$A POST /web/login=$B GET /web=$C"
lbx "sudo journalctl -u haproxy --since @$(( T0/1000 )) -o cat | grep ' 429 ' | head -3" > ${OUT}_429_log_sample.txt
PASS=PASS; (( C429 > 0 )) && echo "$WRONG" | grep -q 429 && [ "$A" = 200 ] && [ "$B" = 303 ] && [ "$C" = 200 ] && ! echo "$EX" | grep -q 429 || PASS=FAIL
printf "S4\t%s\tburst=%s/par%s\tlimit=%s\t200=%s\t429=%s\tother=%s\tfirst429=#%s\tbackend_saw=%s\texempt=%s\tafter=%s/%s/%s\t%s\n" "$TS" "$BURST" "$PAR" "$LIMIT" "$C200" "$C429" "$OTHER" "$FIRST429" "$((B1-B0))" "$(echo $EX | tr ' ' '_')" "$A" "$B" "$C" "$PASS" >> "$RAW/results.tsv"
echo "VERDICT S4 $PASS: $BURST-request burst -> $C200 x 200, $C429 x 429 (first at #$FIRST429, limit $LIMIT/10s), backend saw only $((B1-B0)); exempt client: $EX; normal login afterwards $A/$B/$C"
