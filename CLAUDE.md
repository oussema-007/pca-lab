# PCA Mini-projet 3: Odoo HA Load Balancing lab

You are running on **kali** (the control node) with full autonomy, in `--dangerously-skip-permissions` mode.
Do **not** ask the human questions. Make reasonable decisions, record them in `DECISIONS.md`, and keep going.
Work through the phases in order, verify each one with real tests before moving on, and finish with the deliverables listed at the end.

## 1. The assignment (from the professor)

> Les avantages technologiques que peut apporter un Load Balancer dans toute la chaîne de service d'une plateforme
> d'hébergement rentrant dans le périmètre d'un SMCA d'Entreprise : exemple et démo Application ERP Open Source (EX : ODOO).

In English: the technological benefits a load balancer brings across the whole service chain of a hosting platform that
falls under an enterprise business continuity management system (SMCA / ISO 22301), with an example and a live demo on
an open-source ERP (Odoo).

- Course prerequisites: RHEL 9.x VMs, Docker + Docker Compose, hardened hosts, headless administration over SSH.
- Grading: **20/11/2026** deep technical validation (architecture, justification of choices, test scenarios, live demo),
  then **27/11/2026** 5-minute public presentation. No written report.
- The demo must prove these benefits: **availability**, **maintenance without downtime**, **scalability**, **security at the edge**,
  and each must be measured so it can be tied to continuity objectives (RTO, RPO, service availability).

## 2. Lab inventory (VERIFY FIRST)

| Name  | Current hostname | SSH user | Lab IP (host-only) | NAT IP (internet) | OS | Notes |
|-------|------------------|----------|--------------------|-------------------|----|-------|
| app01 | `rhel-wazuh` | `ouss` | 192.168.100.10 | 192.168.13.136 | RHEL 9.5 | Old LogSentinel Wazuh host. Root disk 44 GB, **only ~3.4 GB free** (old Wazuh data/images) |
| lb01  | `monitored` | `monitored` | 192.168.100.20 (`ens160`, NM connection `hostonly`) | 192.168.13.138 (`ens192`, NM connection `nat`) | RHEL 9.6 | Old LogSentinel monitored VM (web, mail, SSH services, Wazuh agent). Registered with Red Hat (Simple Content Access). 16 GB free |
| kali  | `kali` | `kali` (you run here) | 192.168.100.30 (`eth0`) | 192.168.13.137 (`eth1`, NM connection `Wired connection 1`) | Kali | Control node, k6 load generator, test client. 33 GB free |

Already done by the human (do not undo):
- SSH aliases `app01` and `lb01` exist in `~/.ssh/config` with key auth from kali (`~/.ssh/id_ed25519`). `ssh app01 'sudo -n true'`,
  `ssh lb01 'sudo -n true'` and local `sudo -n true` all succeed.
- Passwordless sudo is provided by `/etc/sudoers.d/90-pca` on all three machines. **Never modify or delete these files.**
- Password SSH login was turned on briefly to copy the key, then turned off. In Phase 0, check that `/etc/ssh/sshd_config.d/00-temp-pass.conf`
  does not exist on app01 or lb01; if it still exists, delete it, run `sshd -t` and restart sshd.
- DNS was fixed: lb01's `nat` connection uses 8.8.8.8 and 1.1.1.1 (`ipv4.ignore-auto-dns yes`); kali's `Wired connection 1` uses 192.168.13.2 and 8.8.8.8;
  app01 resolves fine. Do not change DNS settings unless resolution breaks.
- The old Wazuh containers on app01 were stopped and set to `--restart=no`. They still exist and are removed in Phase 1.
- Name resolution returns IPv6 addresses but the VMware NAT may have no IPv6 route. If downloads hang or time out, make the machine prefer IPv4
  (`precedence ::ffff:0:0/96 100` in `/etc/gai.conf`; for Docker, check `docker pull` works over IPv4) and log it in `DECISIONS.md`.
- A "low disk space on Filesystem root" alert was seen on one machine, source unknown. Phase 0 must record `df -h` for every filesystem on all three.

**Phase 0 must still confirm the real IPs, OS versions, CPU, RAM and disk.** If anything differs from this table, use the real values everywhere
and note it in `DECISIONS.md`.

## 3. Hard rules

1. **Scope:** only touch app01, lb01 and kali. Never scan, connect to or modify anything else on any network.
2. **Never lock yourself out.** Before changing sshd or firewalld on a VM, make sure SSH from kali (192.168.100.30) stays allowed.
   Run `sshd -t` before restarting sshd. Apply firewall changes with `--permanent` and `--reload` only after the SSH rule is in place.
3. **Secrets:** generate strong random passwords yourself (Odoo master password, DB password, HAProxy stats password, demo users).
   Store them only in `~/pca-lab/.secrets` (chmod 600, listed in `.gitignore`). Never print secret values in summaries or docs;
   refer to the file instead. Do not search for, read, reuse or send any API keys or credentials found on the old VMs. Delete them (see Phase 1).
4. **Never run Red Hat registration or ask for Red Hat credentials.** If repos are unavailable, use the container fallback described below
   and log it in `BLOCKERS.md`.
5. **Source of truth:** every config file and script lives in the git repo `~/pca-lab` on kali and is deployed with `scp`/`ssh`.
   Commit after each phase that passes. Before overwriting a file on a VM, back up the original to `/root/pca-backup/` on that VM.
6. **Idempotent scripts:** every script can be re-run safely.
7. **Evidence, not claims:** a phase is done only when its checks pass and the output is saved under `~/pca-lab/evidence/phaseN/`.
8. **While troubleshooting**, do not rewrite `README.md` or `RESULTS.md` on each attempt. Update deliverable docs only once the issue is confirmed solved.
9. **If something only the human can do blocks you** (VMware resources, a VM is down, Red Hat subscription), write it to `BLOCKERS.md`,
   skip what depends on it, finish everything else, and report it at the end.
10. Do not reboot a VM unless a change requires it. If you must, wait for SSH to come back before continuing.

## 4. Phases

### Phase 0: Preflight
- Verify `ssh app01 'sudo -n true'` and `ssh lb01 'sudo -n true'`.
- Collect: hostname, IPs, `/etc/redhat-release`, `nproc`, `free -h`, `df -h`, SELinux mode, firewalld state, `docker version`/`docker compose version`
  (app01; also check lb01), `subscription-manager status`, internet reachability (`dnf repolist`, `curl -I https://registry-1.docker.io`).
- Save to `evidence/phase0/inventory.md`. Create `DECISIONS.md`, `BLOCKERS.md`, `.gitignore`, `.secrets`.

### Phase 1: Clean up the old LogSentinel project
**Disk first:** app01 has only about 3.4 GB free, not enough for the Odoo and PostgreSQL images. Do the app01 Docker cleanup below before
anything else that downloads, then run `docker system prune -a --volumes -f` and `dnf clean all`, and vacuum the journal to 200 MB.
Record `df -h /` before and after in `evidence/phase1/`. Target: at least 15 GB free on app01 before Phase 3. If it is still below 10 GB,
find what remains (`du -xh / --max-depth=3 | sort -h | tail -30`), remove only LogSentinel leftovers, and log anything else in `BLOCKERS.md`.

On **app01**:
- Find the Wazuh Docker Compose project (`docker ps -a`, `docker compose ls`, search for `docker-compose*.yml` containing `wazuh`).
  `docker compose down -v` it, remove its images, its directory, and any leftover Wazuh volumes and networks.
- Remove the old AI scoring agent (Groq): its files, virtualenvs, systemd units, cron jobs, and any environment variable or file
  holding an API key. Securely delete key files (`shred -u`).
- Remove the Wazuh agent package if installed. Close firewalld ports that belonged to Wazuh (1514, 1515, 55000, 9200, 443 dashboard, etc.).

On **lb01**:
- Remove the Wazuh agent. Stop, disable and remove the old demo services (web server, mail: postfix/dovecot, anything else that was
  a LogSentinel target). Keep sshd. Close their firewall ports.
- Ensure the GUI is off: `systemctl get-default` must be `multi-user.target`.

On both: set hostnames `app01` / `lb01`. Update `/etc/hosts` on all three machines (app01, lb01, kali) with the three lab names,
plus `odoo.pca.lab -> <lb01 IP>` on kali. Remove any old "wazuh"/LogSentinel names.
Check: `docker ps -a` empty on app01, `ss -tlnp` shows only sshd (and what you deliberately keep), no Wazuh processes anywhere.

### Phase 2: Baseline hardening (app01, lb01)
- SELinux enforcing, firewalld active and default zone restrictive.
- sshd: `PermitRootLogin no`, `PasswordAuthentication no` (only after confirming key login works), `MaxAuthTries 3`, `X11Forwarding no`.
- `dnf -y update --security` if repos work; `dnf-automatic` not required.
- Chrony time sync working (needed for consistent measurements).
- Record each hardening step and its justification in `evidence/phase2/hardening.md`. This list will be shown to the jury.

### Phase 3: Odoo stack on app01
Directory on app01: `/opt/pca-odoo` (deployed from `~/pca-lab/app01/`).
- `docker-compose.yml` with:
  - `db`: `postgres:16`, named volume, **not published** outside the Docker network, healthcheck with `pg_isready`, memory limit.
  - `odoo-1`, `odoo-2`, `odoo-3`: `odoo:17`, same config, sharing **one named volume for `/var/lib/odoo`** (filestore + sessions) so a user
    session survives a node change. Each publishes HTTP and longpolling on distinct ports bound to app01's lab IP only:
    odoo-1 8069/8072, odoo-2 8169/8172, odoo-3 8269/8272. Memory limits so the three fit with PostgreSQL in about 3 GB total.
- `odoo.conf`: `proxy_mode = True`, `workers = 2`, `max_cron_threads = 1`, `gevent_port = 8072`, `list_db = False`,
  `dbfilter = ^pca_demo$`, `admin_passwd` from `.secrets`, sensible `limit_memory_soft/hard`, `limit_time_real`.
- Create database `pca_demo` once (from one container, `--stop-after-init`) with modules `sale_management` and demo data loaded,
  so there are customers and products to build a sales order in the demo. Create two demo users (e.g. `vendeur1`, `vendeur2`) with
  sales rights; passwords in `.secrets`.
- SELinux: use named volumes or `:Z` on bind mounts. Do not disable SELinux.
- firewalld on app01: allow the six Odoo ports **only from lb01's IP** (rich rules). SSH only from kali.
- Checks: `curl http://<app01>:8069/web/health` (and 8169, 8269) from lb01 returns 200; the same request from kali is refused;
  logging in as a demo user works on each node.

### Phase 4: HAProxy on lb01
- Install with `dnf install haproxy` (RHEL package). Fallback if repos are unavailable: run the official `haproxy` LTS image with
  Docker Compose on lb01 (install Docker CE if needed) and log the reason.
- TLS: create a small local CA on kali (`~/pca-lab/pki/`, key never leaves kali except the server PEM), issue a cert for
  `odoo.pca.lab` with SAN IP of lb01, install the PEM on lb01, trust the CA on kali (`/usr/local/share/ca-certificates` + `update-ca-certificates`).
- `haproxy.cfg` must include:
  - `frontend fe_http` on :80 redirecting to HTTPS.
  - `frontend fe_https` on :443 with TLS, HSTS header, `option forwardfor`, `X-Forwarded-Proto https`, routing `/websocket` to `be_odoo_ws`
    and everything else to `be_odoo`.
  - **Rate limiting:** a stick-table tracking `http_req_rate(10s)` per source IP that returns 429 above a threshold. Design an exemption
    so the load test is not throttled (for example a secret header only k6 sends, stored in `.secrets`), while the rate-limit demo still shows 429.
  - `backend be_odoo`: `balance roundrobin`, `option httpchk GET /web/health`, `http-check expect status 200`,
    `default-server inter 2s fall 3 rise 2`, cookie persistence (`cookie SRV insert indirect nocache httponly secure`),
    `option redispatch`, `retries 3`, servers odoo1/odoo2/odoo3.
  - `backend be_odoo_ws`: same servers on the longpolling ports, `timeout tunnel 1h`.
  - `listen stats` on lb01's IP :8404, `/stats`, auth from `.secrets`, refresh 2s.
  - Runtime API: `stats socket /run/haproxy/admin.sock mode 600 level admin`.
  - Logging to journald/rsyslog so request logs can be shown.
- SELinux: `setsebool -P haproxy_connect_any 1` (needed for the non-standard backend ports). Validate with `haproxy -c -f` before every reload.
- firewalld on lb01: 80/443 from 192.168.100.0/24, 8404 only from kali, SSH only from kali.
- Checks from kali: `curl -sS https://odoo.pca.lab/web/health` is 200 with a trusted cert; repeated requests without the cookie are spread over
  three servers (show via stats CSV or response logs); login through the browser URL works; websocket upgrade to `/websocket` succeeds.

### Phase 5: Demo scenarios (scripts on kali in `~/pca-lab/scenarios/`)
Install k6 on kali (official repo or release binary). Write a k6 script that logs in through `/web/session/authenticate` as a demo user and
performs realistic reads (e.g. `search_read` on `sale.order` and `res.partner`) plus page loads.
Every scenario script prints a one-line verdict and appends its numbers to `results/raw/`.

| # | Script | What it does | Pass criteria |
|---|--------|--------------|---------------|
| S1 | `s1_node_failure.sh` | Runs a probe loop (authenticated request every 200 ms, logs status + latency + server cookie) and a light k6 run, then `docker stop odoo-1`, waits, restarts it | Detection by HAProxy within about 8 s; user-visible failed requests ≤ 1% (target 0 thanks to redispatch); session stays valid |
| S2 | `s2_rolling_update.sh` | Under light k6 load: for each node in turn, runtime API `set server be_odoo/odooN state drain` (and in be_odoo_ws), wait for 0 current sessions, recreate the container, wait for health, `state ready` | 0 failed requests during the whole window |
| S3 | `s3_scaleout.sh` | Same k6 profile twice: with only odoo1 `ready` (others `maint`), then with all three | Report req/s, p95, error rate for both. If app01's CPU count limits the gain, record that honestly with `nproc`/`top` evidence |
| S4 | `s4_rate_limit.sh` | Burst from kali without the exemption header | 429 responses appear above the threshold; normal browsing still works afterwards |
| S5 | `s5_lb_visibility.sh` | Captures the stats page/CSV and a health-check transition from the logs | Evidence that monitoring shows the state changes used in the RTO numbers |

Also write `scenarios/reset_lab.sh`: all containers up and healthy, all servers `ready` in HAProxy, stick-tables cleared. Run it between scenarios.
Run each scenario at least twice and keep the better-documented run, but report both.

### Phase 6 (stretch, only after Phases 0–5 all pass)
In order, stop when RAM gets tight (keep at least 600 MB free on app01):
1. A PostgreSQL streaming replica container on app01 and a scenario showing replication lag (RPO) and manual promotion (RTO).
2. A small Prometheus + Grafana pair on kali scraping HAProxy, only if kali has RAM to spare.

## 5. Deliverables (in `~/pca-lab`, committed)

- `README.md`: architecture (ASCII or Mermaid diagram), IP plan, how each piece is deployed, how to run every scenario, how to reset.
- `RESULTS.md`: a table of measured numbers per scenario (detection time, failed requests, RTO, req/s and p95 at 1 vs 3 nodes, 429 behavior),
  with the exact command that produced each.
- `SMCA-MAPPING.md`: for each benefit (availability, maintenance without downtime, scalability, edge security, observability), the
  continuity objective it supports (RTO, RPO, availability of a critical service, change management without interruption) and the
  evidence from `RESULTS.md`. Also list the residual risks honestly: app01 is a single VM, PostgreSQL has no automatic failover,
  lb01 is a single load balancer, and how each would be treated in production (second node, Patroni, keepalived pair).
- `DEFENSE-NOTES.md`: 15 likely jury questions with short, precise answers (why round-robin vs leastconn, why cookie persistence when sessions
  are shared, what `fall 3 rise 2 inter 2s` means for RTO, what redispatch does, why `proxy_mode`, why `/websocket` has its own backend,
  why `list_db = False`, why backends are filtered by firewalld, etc.).
- `DEMO-CHECKLIST.md`: the exact sequence for the live demo on 20/11, with start-up order, the commands to type, what to show on screen,
  and the reset steps if something goes wrong.
- `DECISIONS.md`, `BLOCKERS.md`, `evidence/`.

## 6. When you finish

Print a final summary: what passed, the key numbers, anything in `BLOCKERS.md`, and the three things the human should read first
to be able to defend the project.
