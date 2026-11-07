#!/bin/bash
# Full campaign: every scenario once (reset between each). Output: results/raw/campaign_<ts>.log + results.tsv lines.
D="$(cd "$(dirname "$0")" && pwd)"
L="$D/../results/raw/campaign_$(date +%Y%m%d-%H%M%S).log"
{
  "$D/s1_node_failure.sh"            | grep VERDICT
  MODE=kill "$D/s1_node_failure.sh"  | grep VERDICT
  "$D/s2_rolling_update.sh"          | grep VERDICT
  "$D/s3_scaleout.sh"                | grep VERDICT
  CPU_PER_NODE=0.66 "$D/s3_scaleout.sh" | grep VERDICT
  "$D/s4_rate_limit.sh"              | grep VERDICT
  "$D/s5_lb_visibility.sh"           | grep VERDICT
  "$D/reset_lab.sh"                  | tail -1
} 2>&1 | tee "$L"
