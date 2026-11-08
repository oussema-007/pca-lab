#!/bin/bash
# Live view for the demo: an authenticated "user" doing 1 request every 200 ms through the LB.
# Prints time, HTTP status, latency, node that answered. Ctrl-C to stop. Usage: ./scenarios/demo_watch.sh [seconds] [pin]
source "$(dirname "$0")/lib.sh"
DUR=${1:-600}; PIN=${2:-}
python3 -I "$LAB/scenarios/probe.py" --duration "$DUR" ${PIN:+--pin $PIN} --out /dev/stdout 2>&1 | \
awk -F, 'NR==1 && /^probe/ {print; next} /^epoch/ {next}
  { split(strftime("%H:%M:%S", int($1/1000)), t, " "); ms=sprintf("%03d", $1%1000);
    ok = ($6==1) ? "\033[32mOK \033[0m" : "\033[41;97mERR\033[0m";
    printf "%s.%s  %s  HTTP %s  %7.1f ms  node=%-6s %s\n", t[1], ms, ok, $2, $3, $4, $7; fflush() }'
