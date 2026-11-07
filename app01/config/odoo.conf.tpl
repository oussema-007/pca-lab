; PCA lab Odoo config. Template in git; rendered with secrets by deploy.sh (never commit the rendered file)
[options]
addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons
data_dir = /var/lib/odoo
db_host = db
db_port = 5432
db_user = odoo
db_password = @@POSTGRES_PASSWORD@@
db_name = pca_demo
dbfilter = ^pca_demo$
list_db = False
admin_passwd = @@ODOO_ADMIN_PASSWD@@
proxy_mode = True
http_port = 8069
gevent_port = 8072
workers = 2
max_cron_threads = 1
db_maxconn = 32
limit_memory_soft = 268435456
limit_memory_hard = 402653184
limit_time_cpu = 120
limit_time_real = 240
limit_request = 8192
log_level = info
