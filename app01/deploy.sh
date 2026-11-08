#!/bin/bash
# Deploy the Odoo stack to app01:/opt/pca-odoo from kali. Idempotent.
#   ./app01/deploy.sh          render config, copy, docker compose up -d, wait healthy
set -euo pipefail
cd "$(dirname "$0")/.."
source ./.secrets
H=app01; DST=/opt/pca-odoo
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/config" "$STAGE/scripts"
sed -e "s|@@POSTGRES_PASSWORD@@|$POSTGRES_PASSWORD|" -e "s|@@ODOO_ADMIN_PASSWD@@|$ODOO_ADMIN_PASSWD|" app01/config/odoo.conf.tpl > "$STAGE/config/odoo.conf"
printf 'POSTGRES_PASSWORD=%s\nREPL_PASSWORD=%s\n' "$POSTGRES_PASSWORD" "$REPL_PASSWORD" > "$STAGE/.env"
cp app01/docker-compose.yml "$STAGE/"
cp app01/scripts/* "$STAGE/scripts/" 2>/dev/null || true
sed "s|@@REPL_PASSWORD@@|$REPL_PASSWORD|" app01/scripts/setup-replication.sql.tpl > "$STAGE/scripts/setup-replication.sql"
rm -f "$STAGE/scripts/setup-replication.sql.tpl"; chmod 600 "$STAGE/scripts/setup-replication.sql"
chmod 600 "$STAGE/.env" "$STAGE/config/odoo.conf"
ssh -q $H "rm -rf /tmp/pca-odoo-stage && mkdir -m 700 /tmp/pca-odoo-stage"
scp -q -r "$STAGE/." $H:/tmp/pca-odoo-stage/
ssh -q $H "sudo bash -s" <<REMOTE
set -euo pipefail
S=/tmp/pca-odoo-stage
mkdir -p /root/pca-backup $DST/config $DST/scripts
# back up previous versions before overwriting
if [ -f $DST/docker-compose.yml ]; then tar -C $DST -czf /root/pca-backup/pca-odoo-\$(date +%Y%m%d-%H%M%S).tgz docker-compose.yml config .env 2>/dev/null || true; fi
install -m 644 -o root -g root \$S/docker-compose.yml $DST/docker-compose.yml
install -m 600 -o root -g root \$S/.env $DST/.env
install -m 640 -o root -g 101 \$S/config/odoo.conf $DST/config/odoo.conf     # gid 101 = odoo user in the image
for f in \$S/scripts/*; do [ -f "\$f" ] && install -m 750 -o root -g root "\$f" $DST/scripts/; done
chmod 755 $DST $DST/config; rm -rf \$S
cd $DST && docker compose config -q
docker compose up -d --remove-orphans db 2>&1 | tail -1
for i in \$(seq 1 30); do docker exec pca-db pg_isready -U odoo -q && break; sleep 2; done
# phase 6: primary-side replication setup (role, slot, pg_hba) - idempotent, password via stdin only
docker exec -i pca-db psql -q -U odoo -d postgres < $DST/scripts/setup-replication.sql
docker exec pca-db bash -c 'grep -q "^host replication replicator" "\$PGDATA/pg_hba.conf" || echo "host replication replicator samenet scram-sha-256" >> "\$PGDATA/pg_hba.conf"'
docker exec pca-db psql -q -U odoo -d postgres -c "select pg_reload_conf()" >/dev/null
ready=\$(docker exec pca-db psql -U odoo -d pca_demo -tAc "select 1 from ir_module_module where name='sale_management' and state='installed'" 2>/dev/null || true)
if [ "\$ready" = 1 ]; then docker compose up -d --remove-orphans 2>&1 | tail -3
else docker compose stop odoo-1 odoo-2 odoo-3 >/dev/null 2>&1 || true; echo "NEED_INIT"; fi
REMOTE
ssh -q $H "sudo docker exec pca-db psql -U odoo -d pca_demo -tAc \"select 1 from ir_module_module where name='sale_management' and state='installed'\" 2>/dev/null | grep -q 1" || { echo "database not initialised: run ./app01/init_db.sh"; exit 0; }
echo "deployed; waiting for health..."
for i in $(seq 1 60); do
  st=$(ssh -q $H "sudo docker ps --format '{{.Names}} {{.Status}}' | grep -E '^(odoo-[123]|pca-db) ' | grep -c '(healthy)'" || true)
  [ "$st" = 4 ] && { echo "all 4 containers healthy"; exit 0; }
  sleep 5
done
echo "WARNING: not all containers healthy"; ssh -q $H "sudo docker ps -a"; exit 1
