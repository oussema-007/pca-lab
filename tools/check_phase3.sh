#!/bin/bash
# Phase 3 checks. Run from kali: ./tools/check_phase3.sh
cd "$(dirname "$0")/.."; source ./.secrets
echo "### $(date -Is) health from lb01 (allowed)"
ssh -q lb01 'for p in 8069 8169 8269; do echo "GET http://192.168.100.10:$p/web/health -> $(curl -sS -m 5 -w " HTTP %{http_code}" http://192.168.100.10:$p/web/health)"; done'
echo "### health from kali (must be refused)"
for p in 8069 8169 8269 8072 8172 8272; do echo "kali -> 192.168.100.10:$p : $(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://192.168.100.10:$p/web/health 2>&1 | head -1)"; done
echo "### PostgreSQL not published: $(ssh -q app01 "sudo ss -tlnH | grep -c ':5432 '") listeners on :5432 on the host"
echo "### login as vendeur1 on each node (from lb01) + search_read sale.order"
ssh -q lb01 "PW='$VENDEUR1_PASSWORD' bash -s" <<'R'
for p in 8069 8169 8269; do
  j=$(mktemp)
  r=$(curl -sS -m 20 -c $j -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"params\":{\"db\":\"pca_demo\",\"login\":\"vendeur1\",\"password\":\"$PW\"}}" http://192.168.100.10:$p/web/session/authenticate)
  uid=$(echo "$r" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("result",{}).get("uid"), d.get("result",{}).get("name"))')
  n=$(curl -sS -m 20 -b $j -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","params":{"model":"sale.order","method":"search_count","args":[[]],"kwargs":{}}}' http://192.168.100.10:$p/web/dataset/call_kw | python3 -c 'import sys,json; print(json.load(sys.stdin).get("result"))')
  echo "port $p: authenticate -> uid/name = $uid ; sale.order count visible = $n"
  rm -f $j
done
R
echo "### session shared between nodes: login on odoo-1, reuse cookie on odoo-3"
ssh -q lb01 "PW='$VENDEUR1_PASSWORD' bash -s" <<'R'
j=$(mktemp)
curl -sS -m 20 -c $j -o /dev/null -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"params\":{\"db\":\"pca_demo\",\"login\":\"vendeur1\",\"password\":\"$PW\"}}" http://192.168.100.10:8069/web/session/authenticate
for p in 8169 8269; do echo "session from 8069 used on $p -> $(curl -sS -m 20 -b $j -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","params":{}}' http://192.168.100.10:$p/web/session/get_session_info | python3 -c 'import sys,json; r=json.load(sys.stdin).get("result",{}); print("uid", r.get("uid"), r.get("username"))')"; done
rm -f $j
R
echo "### containers"; ssh -q app01 "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'; sudo docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'; free -h | head -2"
