#!/bin/bash
# Idempotent firewalld policy for the PCA lab. Usage (as root on the VM): firewall.sh app01|lb01 {apply|commit}
#  apply : add the SSH-from-kali rule first, then the rest, RUNTIME ONLY, arm a 120 s rollback timer
#  commit: (called from kali over a NEW ssh session) persist runtime -> permanent, cancel the timer
set -euo pipefail
ROLE=$1; ACTION=$2
KALI=192.168.100.30; LB=192.168.100.20; LAN=192.168.100.0/24
Z=public
if [ "$ACTION" = commit ]; then
  firewall-cmd --runtime-to-permanent
  systemctl stop pca-fw-rollback.timer 2>/dev/null || true
  echo "committed"; firewall-cmd --zone=$Z --list-all; exit 0
fi
mkdir -p /root/pca-backup; [ -f /root/pca-backup/firewalld-public.xml ] || cp -a /etc/firewalld/zones/public.xml /root/pca-backup/firewalld-public.xml 2>/dev/null || true
systemctl stop pca-fw-rollback.timer 2>/dev/null || true
systemd-run --quiet --unit=pca-fw-rollback --on-active=120 /usr/bin/firewall-cmd --reload
firewall-cmd --set-default-zone=$Z >/dev/null 2>&1 || true
rr(){ firewall-cmd -q --zone=$Z --add-rich-rule="$1" 2>/dev/null || true; }
# 1) SSH from kali only (added BEFORE removing the open ssh service)
rr "rule family=ipv4 source address=$KALI service name=ssh accept"
if [ "$ROLE" = app01 ]; then
  for p in 8069 8072 8169 8172 8269 8272; do rr "rule family=ipv4 source address=$LB port port=$p protocol=tcp accept"; done
fi
if [ "$ROLE" = lb01 ]; then
  rr "rule family=ipv4 source address=$LAN service name=http accept"
  rr "rule family=ipv4 source address=$LAN service name=https accept"
  rr "rule family=ipv4 source address=$KALI port port=8404 protocol=tcp accept"
fi
# 2) close everything that was open to the world
for s in ssh cockpit dhcpv6-client http https; do firewall-cmd -q --zone=$Z --remove-service=$s 2>/dev/null || true; done
for p in $(firewall-cmd --zone=$Z --list-ports); do firewall-cmd -q --zone=$Z --remove-port=$p; done
echo "runtime applied; rollback in 120 s unless committed"
