#!/bin/bash
# Default-deny for traffic entering Docker containers from the physical NICs (Docker DNAT bypasses firewalld zones).
# Only lb01 may open connections to the Odoo containers (container ports 8069 http, 8072 websocket).
# Idempotent: DOCKER-USER is owned by us (Docker never writes to it), so we flush and rebuild it.
set -euo pipefail
LB=192.168.100.20
for i in $(seq 1 30); do iptables -nL DOCKER-USER >/dev/null 2>&1 && break; sleep 1; done
iptables -F DOCKER-USER
iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -A DOCKER-USER -i ens160 -s $LB -p tcp -m multiport --dports 8069,8072 -m comment --comment "pca: lb01 -> odoo" -j RETURN
iptables -A DOCKER-USER -i ens+ -m conntrack --ctstate NEW -m comment --comment "pca: default deny to containers" -j REJECT --reject-with tcp-reset -p tcp
iptables -A DOCKER-USER -i ens+ -m conntrack --ctstate NEW -m comment --comment "pca: default deny to containers" -j REJECT
iptables -A DOCKER-USER -j RETURN
echo "DOCKER-USER rules applied"
