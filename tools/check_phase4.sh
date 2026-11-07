#!/bin/bash
# Phase 4 checks from kali. ./tools/check_phase4.sh
cd "$(dirname "$0")/.."; source ./.secrets
U=https://odoo.pca.lab
echo "### $(date -Is)"
echo "### 1. health through the LB with the system trust store (no -k)"
curl -sS -w '  -> HTTP %{http_code}, TLS verify result=%{ssl_verify_result}, %{http_version}\n' $U/web/health
echo "### 2. certificate presented"
echo | openssl s_client -connect odoo.pca.lab:443 -servername odoo.pca.lab 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName | tr '\n' ' '; echo
echo "    TLS 1.1 refused: $(echo | openssl s_client -connect odoo.pca.lab:443 -tls1_1 2>&1 | grep -qiE 'alert|no protocols|wrong version|unsupported' && echo yes || echo NO)"
echo "### 3. HTTP -> HTTPS redirect"
curl -sS -o /dev/null -w '  http://odoo.pca.lab/ -> %{http_code} Location: %{redirect_url}\n' http://odoo.pca.lab/
echo "### 4. security headers on /web/login"
curl -sS -o /dev/null -D - $U/web/login | grep -iE '^(strict-transport|x-content-type|x-frame|referrer-policy|set-cookie: SRV|server:)' | sed 's/^/  /'
echo "### 5. round robin: 30 requests without cookie -> server cookie assigned"
for i in $(seq 1 30); do curl -sS -o /dev/null -D - $U/web/login | grep -oiE 'SRV=odoo[0-9]'; done | sort | uniq -c | sed 's/^/  /'
echo "### 6. persistence: same cookie -> same server (10 requests with SRV=odoo2)"
for i in $(seq 1 10); do curl -sS -o /dev/null -b 'SRV=odoo2' -w '%{http_code} ' $U/web/health; done; echo
echo "### 7. form login through the public URL (as a browser does: GET /web/login, csrf, POST)"
J=$(mktemp); P=$(mktemp)
curl -sS -c $J -b $J $U/web/login -o $P
CSRF=$(grep -oP 'name="csrf_token" value="\K[^"]+' $P)
curl -sS -c $J -b $J -o /dev/null -w '  POST /web/login -> %{http_code} redirect=%{redirect_url}\n' --data-urlencode "csrf_token=$CSRF" --data-urlencode "login=vendeur1" --data-urlencode "password=$VENDEUR1_PASSWORD" --data-urlencode "redirect=" $U/web/login
curl -sS -b $J -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","params":{}}' $U/web/session/get_session_info | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print("  session_info: uid=%s login=%s db=%s" % (r["uid"], r["username"], r["db"]))'
curl -sS -b $J -o /dev/null -w '  GET /web#action=sale.action_orders (web client) -> %{http_code}\n' "$U/web#action=sale.action_orders"
echo "  server cookie for this browser session: $(grep -oE 'SRV\s+odoo[0-9]' $J | awk '{print $2}')"
echo "### 8. websocket upgrade on /websocket (be_odoo_ws, gevent port)"
curl -sS -m 5 -o /dev/null -b $J --http1.1 -w '  -> HTTP %{http_code}\n' -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" -H "Origin: $U" "$U/websocket" 2>&1 | grep -v 'timed out'
rm -f $J $P
echo "### 9. database manager blocked at the edge"
curl -sS -o /dev/null -w '  /web/database/manager -> %{http_code}\n' $U/web/database/manager
echo "### 10. stats page (kali only, auth)"
curl -sS -o /dev/null -w '  no auth  -> %{http_code}\n' http://lb01:8404/stats
curl -sS -o /dev/null -w '  with auth -> %{http_code}\n' -u "$HAPROXY_STATS_USER:$HAPROXY_STATS_PASSWORD" http://lb01:8404/stats
echo "### 11. boundaries"
echo "  app01 -> lb01:8404 (not kali): $(ssh -q app01 'curl -sS -m 4 -o /dev/null -w %{http_code} http://192.168.100.20:8404/stats 2>&1 | tail -c 60' </dev/null)"
echo "  app01 -> lb01:443 (lab subnet allowed): $(ssh -q app01 'curl -sS -m 4 -k -o /dev/null -w %{http_code} https://192.168.100.20/web/health 2>&1' </dev/null)"
echo "  kali NAT -> lb01 NAT IP 443: $(curl -sS -m 4 -k --interface 192.168.13.137 -o /dev/null -w %{http_code} https://192.168.13.138/web/health 2>&1 | tail -c 70)"
echo "### 12. HAProxy server state (runtime API)"
ssh -q lb01 'echo "show stat" | sudo socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18,37,8 | grep -E "odoo[123]|BACKEND" | column -ts,' </dev/null | sed 's/^/  /'
