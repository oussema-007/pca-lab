#!/bin/bash
# Idempotent sshd hardening. Run on a VM as root. Key login was verified from kali before running.
set -euo pipefail
SRC=/tmp/01-pca-hardening.conf
D=/etc/ssh/sshd_config.d
mkdir -p /root/pca-backup/sshd_config.d
cp -an $D/. /root/pca-backup/sshd_config.d/ 2>/dev/null || true
install -m 600 -o root -g root $SRC $D/01-pca-hardening.conf
rm -f $D/99-logsentinel.conf          # superseded (old LogSentinel file, backed up)
restorecon -F $D/01-pca-hardening.conf
if sshd -t; then systemctl reload sshd; echo "sshd reloaded"; else
  echo "sshd -t FAILED, restoring"; rm -f $D/01-pca-hardening.conf; cp -a /root/pca-backup/sshd_config.d/99-logsentinel.conf $D/ 2>/dev/null; exit 1; fi
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries|x11forwarding|allowtcpforwarding|logingracetime) '
