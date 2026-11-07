#!/bin/bash
# Idempotent creation of database pca_demo (sale_management + demo data + fr_FR) and demo users.
# Run from kali after ./app01/deploy.sh. Odoo nodes are stopped during init (no concurrent registry load).
set -euo pipefail
cd "$(dirname "$0")/.."
source ./.secrets
H=app01
q(){ ssh -q $H "sudo docker exec pca-db psql -U odoo -d postgres -tAc \"$1\""; }
installed=$(ssh -q $H "sudo docker exec pca-db psql -U odoo -d pca_demo -tAc \"select 1 from ir_module_module where name='sale_management' and state='installed'\" 2>/dev/null" || true)
ssh -q $H "cd /opt/pca-odoo && sudo docker compose stop odoo-1 odoo-2 odoo-3 >/dev/null 2>&1 || true"
if [ "$installed" != 1 ]; then
  echo "(re)creating pca_demo: drop half-initialised DB if any, then install sale_management with demo data"
  q "drop database if exists pca_demo with (force)" >/dev/null
  ssh -q $H "cd /opt/pca-odoo && sudo docker compose run --rm --no-deps -T odoo-1 odoo -c /etc/odoo/odoo.conf -d pca_demo -i sale_management --load-language=fr_FR --stop-after-init --no-http --workers=0 --max-cron-threads=0 2>&1 | grep -E 'Modules loaded|ERROR|CRITICAL|Registry loaded' | tail -5"
else
  echo "pca_demo already initialised, skipping creation"
fi
echo "configuring admin password, vendeur1/vendeur2, base url..."
ssh -q $H "cd /opt/pca-odoo && sudo docker compose run --rm --no-deps -T -e ADMIN_PW='$ODOO_DB_ADMIN_PASSWORD' -e V1='$VENDEUR1_PASSWORD' -e V2='$VENDEUR2_PASSWORD' odoo-1 odoo shell -c /etc/odoo/odoo.conf -d pca_demo --no-http --workers=0 --max-cron-threads=0 --log-level=warn 2>&1 | grep -E '^(USER|COUNTS|Traceback|.*Error)'" <<'PY'
import os
Users = env['res.users'].with_context(no_reset_password=True)
env.ref('base.user_admin').write({'password': os.environ['ADMIN_PW']})
groups = [env.ref('base.group_user').id, env.ref('sales_team.group_sale_salesman_all_leads').id]
for login, pw, name in [('vendeur1', os.environ['V1'], 'Vendeur 1'), ('vendeur2', os.environ['V2'], 'Vendeur 2')]:
    vals = {'name': name, 'login': login, 'password': pw, 'lang': 'fr_FR', 'tz': 'Africa/Tunis', 'groups_id': [(6, 0, groups)]}
    u = Users.search([('login', '=', login)])
    u.write(vals) if u else Users.create(vals)
    print('USER', login, 'ok')
ICP = env['ir.config_parameter'].sudo()
ICP.set_param('web.base.url', 'https://odoo.pca.lab')
ICP.set_param('web.base.url.freeze', 'True')
print('COUNTS sale.order=%d res.partner=%d product=%d demo=%s' % (env['sale.order'].search_count([]), env['res.partner'].search_count([]), env['product.product'].search_count([]), env.ref('base.module_base').demo))
env.cr.commit()
PY
ssh -q $H "cd /opt/pca-odoo && sudo docker compose up -d 2>&1 | tail -1"
echo "init done"
