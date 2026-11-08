#!/bin/bash
# Bring the lab back to a known state: all containers up + healthy, every HAProxy server READY and UP, stick-table cleared.
source "$(dirname "$0")/lib.sh"
log "reset: docker compose up -d on app01"
app "cd /opt/pca-odoo && sudo docker compose up -d 2>&1 | tail -1" || true
for c in pca-db odoo-1 odoo-2 odoo-3; do t=$(wait_healthy $c 240) || { echo "RESET FAILED: $c not healthy"; exit 1; }; done
for b in be_odoo be_odoo_ws; do for s in odoo1 odoo2 odoo3; do hap "set server $b/$s state ready" >/dev/null; done; done
for b in be_odoo be_odoo_ws; do for s in odoo1 odoo2 odoo3; do wait_status $b $s '^UP$' 60 >/dev/null || { echo "RESET FAILED: $b/$s $(srv_status $b $s)"; exit 1; }; done; done
for n in 1 2 3; do warm_node $n; done      # cold nodes after a restart answer slowly at first
hap "clear table fe_https" >/dev/null
hap "clear counters" >/dev/null
echo "RESET OK: 4 containers healthy, 6/6 HAProxy servers UP, stick-table cleared ($(date +%T))"
