#!/bin/bash
echo "== $(hostname) $(date -Is) kernel $(uname -r)"
echo "-- SELinux: $(getenforce) (config: $(grep ^SELINUX= /etc/selinux/config))"
echo "-- firewalld: $(systemctl is-active firewalld), default zone $(sudo firewall-cmd --get-default-zone)"
sudo firewall-cmd --zone=public --list-all | grep -E "services|ports:|rule"
echo "-- sshd effective:"; sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries|x11forwarding|allowtcpforwarding|logingracetime|pubkeyauthentication) '
echo "-- chrony: $(systemctl is-active chronyd)"; chronyc tracking | grep -E "Reference|System time|Leap"
echo "-- disabled services:"; for s in cups avahi-daemon cockpit.socket; do echo "   $s: $(systemctl is-enabled $s 2>/dev/null)/$(systemctl is-active $s 2>/dev/null)"; done
echo "-- default target: $(systemctl get-default)"
echo "-- listening:"; sudo ss -tlnH | awk '{print "   "$4}'
