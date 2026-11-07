#!/bin/bash
echo "-- $(hostname) $(date -Is) default target: $(systemctl get-default)"
df -h /
echo "-- docker ps -a"; command -v docker >/dev/null && sudo docker ps -a || echo "docker not installed"
echo "-- ss -tlnp"; sudo ss -tlnp
echo "-- wazuh/ossec/groq processes (by command name):"; ps -eo pid,comm,args --no-headers | awk '$2 ~ /wazuh|ossec|filebeat|opensearch/ || $0 ~ /ai_agent\.py/' | grep -v awk || true; echo "(end)"
echo "-- leftover packages:"; rpm -qa | grep -iE "wazuh|nginx|postfix" || echo none
echo "-- firewalld: services=$(sudo firewall-cmd --list-services) ports=$(sudo firewall-cmd --list-ports)"
