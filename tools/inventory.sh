#!/bin/bash
# Read-only inventory of a lab host. Usage: ssh host 'bash -s' < tools/inventory.sh
echo "### hostname"; hostname
echo "### ip -br addr"; ip -br addr
echo "### ip route"; ip route
echo "### release"; cat /etc/redhat-release 2>/dev/null || head -3 /etc/os-release
echo "### uname"; uname -r
echo "### nproc"; nproc
echo "### lscpu"; lscpu | grep -E 'Model name|^CPU\(s\)'
echo "### free -h"; free -h
echo "### df -h"; df -h
echo "### selinux"; getenforce 2>/dev/null || echo n/a
echo "### firewalld"; systemctl is-active firewalld; sudo firewall-cmd --get-default-zone 2>/dev/null; sudo firewall-cmd --list-all 2>/dev/null
echo "### docker"; sudo docker version --format 'server {{.Server.Version}}' 2>&1 | head -2; sudo docker compose version 2>&1 | head -1
echo "### subscription"; sudo subscription-manager status 2>&1 | head -8
echo "### dnf repolist"; sudo timeout 120 dnf -q repolist 2>&1 | head -15
echo "### curl registry"; timeout 20 curl -sSI https://registry-1.docker.io/v2/ 2>&1 | head -1
echo "### sshd_config.d"; ls -l /etc/ssh/sshd_config.d/ 2>&1
echo "### default target"; systemctl get-default
echo "### listening"; sudo ss -tlnp
