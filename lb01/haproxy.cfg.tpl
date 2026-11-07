#---------------------------------------------------------------------
# PCA lab - HAProxy 2.4 (RHEL 9 package) on lb01, edge of the Odoo platform
# Template in git: ~/pca-lab/lb01/haproxy.cfg.tpl ; placeholders are filled from .secrets by lb01/deploy.sh
#---------------------------------------------------------------------
global
    log stdout format short local0 info          # -> journald (journalctl -u haproxy)
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    maxconn 4000
    stats socket /run/haproxy/admin.sock mode 600 level admin expose-fd listeners
    stats timeout 30s
    # TLS: modern profile, TLS 1.2+ only
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    mode http
    log global
    option httplog
    option dontlognull
    option redispatch                  # on retry, allow another server than the one in the cookie
    retries 3
    timeout connect 3s
    timeout client 60s
    timeout server 250s                # > Odoo limit_time_real (240 s)
    timeout http-request 10s           # slowloris protection
    timeout http-keep-alive 10s
    timeout queue 30s
    timeout check 2s
    maxconn 3000

#---------------------------------------------------------------------
frontend fe_http
    bind 192.168.100.20:80
    http-request redirect scheme https code 301

frontend fe_https
    bind 192.168.100.20:443 ssl crt /etc/haproxy/certs/odoo.pca.lab.pem alpn h2,http/1.1
    option forwardfor
    # unique id in every log line (correlation with k6/probe logs)
    unique-id-format %{+X}o\ %ci:%cp_%fi:%fp_%Ts_%rt:%pid
    unique-id-header X-Request-ID
    # %hr = captured {SRV cookie sent by client|req rate of this IP over 10s}
    log-format "%ci:%cp [%tr] %ft %b/%s %TR/%Tw/%Tc/%Tr/%Ta %ST %B %tsc %ac/%fc/%bc/%sc/%rc %sq/%bq %hr %ID \"%HM %HPO\""

    # --- edge security --------------------------------------------------
    # rate limit: requests per source IP over a sliding 10 s window
    stick-table type ip size 100k expire 60s store http_req_rate(10s),http_err_rate(10s)
    acl loadtest   req.hdr(@@LOADTEST_HEADER_NAME@@) -m str @@LOADTEST_HEADER_VALUE@@
    acl too_fast   sc_http_req_rate(0) gt @@RATE_LIMIT@@
    http-request track-sc0 src unless loadtest
    http-request capture req.cook(SRV) len 8
    http-request capture sc_http_req_rate(0) len 6
    http-request deny deny_status 429 if !loadtest too_fast
    http-request set-var(txn.trusted) bool(true) if loadtest
    http-request del-header @@LOADTEST_HEADER_NAME@@          # never forwarded to Odoo
    # Odoo database manager is never reachable from the outside (defence in depth with list_db=False)
    http-request deny deny_status 403 if { path_beg /web/database }
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Host %[req.hdr(host)]
    http-response set-header Strict-Transport-Security "max-age=31536000; includeSubDomains"
    http-response set-header X-Content-Type-Options nosniff
    http-response set-header X-Frame-Options SAMEORIGIN
    http-response set-header Referrer-Policy strict-origin-when-cross-origin
    http-response del-header Server
    http-response del-header X-Powered-By
    # which backend server answered: only shown to trusted test clients (scenario probes), never to normal users
    http-response set-header X-PCA-Server %s if { var(txn.trusted) -m bool }

    # --- routing ---------------------------------------------------------
    acl is_ws path_beg /websocket
    use_backend be_odoo_ws if is_ws
    default_backend be_odoo

#---------------------------------------------------------------------
backend be_odoo
    balance roundrobin
    # Odoo needs a Host header (KeyError HTTP_HOST otherwise) -> HTTP/1.1 check with Host
    option httpchk
    http-check send meth GET uri /web/health ver HTTP/1.1 hdr Host odoo.pca.lab
    http-check expect status 200
    cookie SRV insert indirect nocache httponly secure
    # failover without user-visible errors:
    #  - redispatch on EVERY retry (default = only the last one, after ~1 s turn-around delays on the dead server)
    #  - L7 retry when the server died before sending a single byte (worker killed / node stopping)
    option redispatch 1
    retry-on conn-failure empty-response
    option http-buffer-request         # whole request buffered first: required to replay it (and blocks slow-POST)
    default-server inter 2s fall 3 rise 2 maxconn 32 check
    server odoo1 192.168.100.10:8069 cookie odoo1
    server odoo2 192.168.100.10:8169 cookie odoo2
    server odoo3 192.168.100.10:8269 cookie odoo3

backend be_odoo_ws
    # long-lived websocket connections (Odoo bus / gevent worker on 8072)
    balance leastconn
    # Odoo needs a Host header (KeyError HTTP_HOST otherwise) -> HTTP/1.1 check with Host
    option httpchk
    http-check send meth GET uri /web/health ver HTTP/1.1 hdr Host odoo.pca.lab
    http-check expect status 200
    timeout tunnel 1h
    default-server inter 2s fall 3 rise 2 check
    server odoo1 192.168.100.10:8072
    server odoo2 192.168.100.10:8172
    server odoo3 192.168.100.10:8272

#---------------------------------------------------------------------
listen stats
    bind 192.168.100.20:8404
    mode http
    log global
    option dontlog-normal
    stats enable
    stats uri /stats
    stats refresh 2s
    stats show-legends
    stats show-node
    stats auth @@HAPROXY_STATS_USER@@:@@HAPROXY_STATS_PASSWORD@@
    # Prometheus metrics (scraped from kali, port 8404 is firewalled to kali only)
    http-request use-service prometheus-exporter if { path /metrics }
