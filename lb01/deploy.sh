#!/bin/bash
# Deploy HAProxy config + TLS bundle to lb01. Idempotent. Validates with `haproxy -c` before reload.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./.secrets
RATE_LIMIT=${RATE_LIMIT:-200}     # requests per 10 s per source IP (see DECISIONS.md)
H=lb01
./pki/make_pki.sh >/dev/null
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT; chmod 700 "$STAGE"
sed -e "s|@@LOADTEST_HEADER_NAME@@|$LOADTEST_HEADER_NAME|g" -e "s|@@LOADTEST_HEADER_VALUE@@|$LOADTEST_HEADER_VALUE|g" \
    -e "s|@@HAPROXY_STATS_USER@@|$HAPROXY_STATS_USER|g" -e "s|@@HAPROXY_STATS_PASSWORD@@|$HAPROXY_STATS_PASSWORD|g" \
    -e "s|@@RATE_LIMIT@@|$RATE_LIMIT|g" lb01/haproxy.cfg.tpl > "$STAGE/haproxy.cfg"
grep -q '@@' "$STAGE/haproxy.cfg" && { echo "unrendered placeholder"; exit 1; }
cp pki/odoo.pca.lab.pem lb01/pca-haproxy.tmpfiles.conf "$STAGE/"
ssh -q $H "rm -rf /tmp/pca-lb-stage; mkdir -m 700 /tmp/pca-lb-stage"
scp -q "$STAGE"/* $H:/tmp/pca-lb-stage/
ssh -q $H "sudo bash -s" <<'REMOTE'
set -euo pipefail
S=/tmp/pca-lb-stage
mkdir -p /root/pca-backup /etc/haproxy/certs
[ -f /root/pca-backup/haproxy.cfg.orig ] || cp -a /etc/haproxy/haproxy.cfg /root/pca-backup/haproxy.cfg.orig
cp -a /etc/haproxy/haproxy.cfg /root/pca-backup/haproxy.cfg.prev
# runtime dir for the admin socket (+ SELinux label)
install -m 644 $S/pca-haproxy.tmpfiles.conf /etc/tmpfiles.d/pca-haproxy.conf
[ "$(semanage fcontext -l -C | grep -c '^/var/run/haproxy(/')" -gt 0 ] || semanage fcontext -a -t haproxy_var_run_t '/var/run/haproxy(/.*)?'
systemd-tmpfiles --create /etc/tmpfiles.d/pca-haproxy.conf; restorecon -R /run/haproxy
# SELinux: allow haproxy_t to connect to the non-standard Odoo ports (8069/8072/8169/...)
[ "$(getsebool haproxy_connect_any | awk '{print $3}')" = on ] || setsebool -P haproxy_connect_any 1
install -m 640 -o root -g haproxy $S/odoo.pca.lab.pem /etc/haproxy/certs/odoo.pca.lab.pem
install -m 640 -o root -g haproxy $S/haproxy.cfg /etc/haproxy/haproxy.cfg.new
restorecon -R /etc/haproxy
if haproxy -c -q -f /etc/haproxy/haproxy.cfg.new -f /etc/haproxy/conf.d; then
  mv /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg; restorecon /etc/haproxy/haproxy.cfg
  systemctl enable -q haproxy
  if systemctl is-active -q haproxy; then systemctl reload haproxy; echo "haproxy reloaded"; else systemctl start haproxy; echo "haproxy started"; fi
else
  echo "CONFIG INVALID - kept previous config"; rm -f /etc/haproxy/haproxy.cfg.new; exit 1
fi
rm -rf $S
REMOTE
