#!/bin/bash
# Phase 6: Prometheus + Grafana on kali (podman, host network, bound to 127.0.0.1). Idempotent.
set -euo pipefail
cd "$(dirname "$0")"; M=$(pwd)
source ../.secrets
PROM=docker.io/prom/prometheus:v2.55.1
GRAF=docker.io/grafana/grafana-oss:11.3.0
podman volume exists pca-prom || podman volume create pca-prom >/dev/null
podman volume exists pca-grafana || podman volume create pca-grafana >/dev/null
podman rm -f pca-prometheus pca-grafana >/dev/null 2>&1 || true
podman run -d --name pca-prometheus --network host --memory 300m --restart unless-stopped \
  -v "$M/prometheus.yml:/etc/prometheus/prometheus.yml:ro,Z" -v pca-prom:/prometheus \
  $PROM --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.retention.time=3d --web.listen-address=127.0.0.1:9090 >/dev/null
podman run -d --name pca-grafana --network host --memory 300m --restart unless-stopped \
  -e GF_SERVER_HTTP_ADDR=127.0.0.1 -e GF_SERVER_HTTP_PORT=3000 \
  -e GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD" \
  -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer \
  -e GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/pca-haproxy.json \
  -e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
  -v "$M/grafana/provisioning:/etc/grafana/provisioning:ro,Z" -v "$M/grafana/dashboards:/var/lib/grafana/dashboards:ro,Z" \
  -v pca-grafana:/var/lib/grafana/data $GRAF >/dev/null
for i in $(seq 1 60); do curl -fsS -o /dev/null http://127.0.0.1:3000/api/health && break; sleep 1; done
echo "Prometheus http://127.0.0.1:9090  Grafana http://127.0.0.1:3000 (anonymous viewer; admin password in .secrets)"
