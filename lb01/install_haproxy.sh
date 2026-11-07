#!/bin/bash
# Idempotent: install the Red Hat haproxy RPM on lb01 from the RHEL DVD attached to the VM (CDN access is blocked, BLOCKERS B1).
set -euo pipefail
if rpm -q haproxy socat >/dev/null; then echo "haproxy already installed: $(rpm -q haproxy)"; rpm -q --qf "signature: %{SIGPGP:pgpsig}\n" haproxy; mountpoint -q /mnt/rhel-dvd && umount /mnt/rhel-dvd; exit 0; fi
mkdir -p /mnt/rhel-dvd
mountpoint -q /mnt/rhel-dvd || mount -o ro /dev/sr1 /mnt/rhel-dvd
cat > /etc/yum.repos.d/rhel-dvd.repo <<R
[rhel-dvd-baseos]
name=RHEL 9.6 DVD BaseOS (local, read-only)
baseurl=file:///mnt/rhel-dvd/BaseOS
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
[rhel-dvd-appstream]
name=RHEL 9.6 DVD AppStream (local, read-only)
baseurl=file:///mnt/rhel-dvd/AppStream
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
R
dnf -y --disablerepo='*' --enablerepo='rhel-dvd-*' install haproxy socat
rpm -q haproxy; rpm -q --qf "signature: %{SIGPGP:pgpsig}\n" haproxy
umount /mnt/rhel-dvd
