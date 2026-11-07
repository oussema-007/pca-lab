#!/bin/bash
# Shared helpers for the PCA demo scenarios (sourced, not executed).
set -euo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$LAB/.secrets"
export BASE=https://odoo.pca.lab
export PCA_HDR_NAME="$LOADTEST_HEADER_NAME" PCA_HDR_VALUE="$LOADTEST_HEADER_VALUE"
export PCA_PW1="$VENDEUR1_PASSWORD" PCA_PW2="$VENDEUR2_PASSWORD"
RAW="$LAB/results/raw"; mkdir -p "$RAW"
TS=$(date +%Y%m%d-%H%M%S)
now_ms(){ date +%s%3N; }
log(){ echo "[$(date +%H:%M:%S.%3N)] $*"; }
app(){ ssh -q app01 "$@" </dev/null; }
lbx(){ ssh -q lb01 "$@" </dev/null; }
# HAProxy runtime API (admin socket on lb01)
hap(){ ssh -q lb01 "echo '$*' | sudo socat stdio /run/haproxy/admin.sock" </dev/null; }
# show stat columns: 1 pxname 2 svname 5 scur 8 stot 14 econ 15 eresp 16 wretr 17 wredis 18 status 24 lastchg
srv_field(){ hap "show stat" | awk -F, -v b="$1" -v s="$2" -v f="$3" '$1==b && $2==s {print $f}'; }
srv_status(){ srv_field "$1" "$2" 18; }
wait_status(){ # backend server regex timeout_s -> waits until status matches, prints elapsed ms
  local b=$1 s=$2 re=$3 to=${4:-120} t0; t0=$(now_ms)
  while :; do st=$(srv_status "$b" "$s"); [[ "$st" =~ $re ]] && { echo $(( $(now_ms) - t0 )); return 0; }
    (( $(now_ms) - t0 > to*1000 )) && { echo "TIMEOUT($st)"; return 1; }; sleep 0.25; done; }
container_healthy(){ app "sudo docker inspect -f '{{.State.Health.Status}}' $1" 2>/dev/null; }
wait_healthy(){ local c=$1 to=${2:-180} t0; t0=$(now_ms)
  while [ "$(container_healthy "$c")" != healthy ]; do (( $(now_ms) - t0 > to*1000 )) && return 1; sleep 1; done; echo $(( $(now_ms) - t0 )); }
k6run(){ # name vus duration think [extra k6 args...]
  local name=$1 vus=$2 dur=$3 think=$4; shift 4
  VUS=$vus DURATION=$dur THINK=$think SUMMARY="$RAW/${name}_k6.json" k6 run --quiet --no-color "$@" "$LAB/scenarios/k6/odoo_load.js"; }
k6json(){ # file -> "reqs rps p95 failed_rate failed_count rpc_errors"
  python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))["metrics"]
g=lambda m,k,default=0: d.get(m,{}).get("values",{}).get(k,default)
print(int(g("http_reqs","count")), round(g("http_reqs","rate"),1), round(g("http_req_duration","p(95)"),1), round(g("http_req_failed","rate"),5), int(g("http_req_failed","passes")), int(g("rpc_errors","count")))' "$1"; }
