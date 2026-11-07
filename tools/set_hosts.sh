#!/bin/bash
# Idempotent: (re)writes a marked PCA block in /etc/hosts, drops old wazuh names.
# Usage: sudo bash set_hosts.sh [with-vip]   (with-vip adds odoo.pca.lab -> lb01, used on kali)
set -euo pipefail
F=/etc/hosts
mkdir -p /root/pca-backup 2>/dev/null || true
[ -f /root/pca-backup/hosts.orig ] || cp -a $F /root/pca-backup/hosts.orig 2>/dev/null || true
tmp=$(mktemp)
sed '/# BEGIN PCA-LAB/,/# END PCA-LAB/d' $F | grep -viE 'wazuh|logsentinel' > "$tmp" || true
{
  echo "# BEGIN PCA-LAB (managed by ~/pca-lab/tools/set_hosts.sh)"
  echo "192.168.100.10 app01 app01.pca.lab"
  echo "192.168.100.20 lb01 lb01.pca.lab"
  echo "192.168.100.30 kali kali.pca.lab"
  [ "${1:-}" = with-vip ] && echo "192.168.100.20 odoo.pca.lab"
  echo "# END PCA-LAB"
} >> "$tmp"
cat "$tmp" > $F; rm -f "$tmp"
