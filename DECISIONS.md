# Decisions log

Format: date - decision - reason.

## Phase 0
- 2026-11-07 - Real OS on both VMs is **RHEL 9.8** (table said 9.5/9.6). Real values used everywhere.
- 2026-11-07 - app01 NAT interface is `ens224` (not documented). app01 RAM is 4.8 GiB, lb01 RAM is 1.0 GiB, all machines have 2 vCPU. The memory budget for the Odoo stack (~3 GiB) fits app01; lb01 only runs HAProxy (native package, no Docker) to stay inside 1 GiB.
- 2026-11-07 - Secrets generated with `openssl rand`, stored only in `~/pca-lab/.secrets` (600, git-ignored). The k6 rate-limit exemption is a secret header (`LOADTEST_HEADER_NAME` / `LOADTEST_HEADER_VALUE`).
- 2026-11-07 - lb01 cannot reach Red Hat CDN (403, consumer deleted). Rule 4 forbids registration. Instead of the Docker fallback I use the **RHEL 9.6 DVD already attached to lb01** as a local read-only dnf repo (`file:///mnt/rhel-dvd/{BaseOS,AppStream}`): HAProxy stays the signed Red Hat RPM managed by systemd, which is lighter than Docker on a 1 GiB VM and keeps SELinux policy (`haproxy_t`). Trade-off: no security errata on lb01 until the subscription is fixed (BLOCKERS B1).

## Phase 1
- 2026-11-07 - Wazuh stack lived at `/home/ouss/wazuh-docker/single-node` (Compose project `single-node`, 3 containers, 14 volumes, 12.4 GB). Removed with `docker compose down -v --rmi all`, then `docker system prune -a --volumes -f`, `dnf clean all`, journal vacuum. app01 free space went from **2.8 GB to 23 GB** (evidence/phase1/app01-before.txt, verify.txt).
- 2026-11-07 - Groq "AI scoring agent" = `/home/ouss/logsentinel-ai` (ai_agent.py + venv, no systemd unit / cron / env var found). All non-library files `shred -u`, directory and pip cache removed. Contents were never displayed.
- 2026-11-07 - Old private keys from LogSentinel (`cert-build/logsentinel-ca.key`, `cert-backup-2026-10-02/wazuh.dashboard-key.pem`) shredded with their directories.
- 2026-11-07 - **Not removed** (not LogSentinel, belong to other coursework of the owner): `/home/ouss/dfir-wk0*`, `/home/ouss/amir-s0-package*` on app01. They contain a folder named `07-wazuh` (DFIR evidence), left untouched.
- 2026-11-07 - lb01: removed wazuh-agent RPM + `/var/ossec` + wazuh repo + SELinux module `wazuh`, nginx, postfix (removal offline with `--disablerepo='*'`), the LogSentinel brute-force victim account `backupsvc` and its sshd `Match` drop-in that allowed password login. Originals of config files in `/root/pca-backup/`.
- 2026-11-07 - Also disabled on both VMs: `cups` (printing, not needed on servers) and `avahi-daemon` (mDNS, still advertised `rhel-wazuh.local`). Smaller attack surface, less RAM.
- 2026-11-07 - app01 boot target set to `multi-user.target` and switched live (`systemctl isolate`): GDM off saves ~0.7 GB RAM for Odoo.
- 2026-11-07 - `/etc/hosts` handled by `tools/set_hosts.sh` with a marked block (idempotent); unrelated entries on kali from other labs are left alone.

## Phase 2
- 2026-11-07 - sshd hardening in `/etc/ssh/sshd_config.d/01-pca-hardening.conf` (sorted before `50-redhat.conf`, first value wins). Old `99-logsentinel.conf` replaced (backup in `/root/pca-backup/sshd_config.d/`). Also `AllowTcpForwarding no`: no tunnels are needed in this lab.
- 2026-11-07 - firewalld: kept zone `public` (target default = REJECT, so blocked clients get an immediate "connection refused", easy to show) and removed every open service (ssh, cockpit, dhcpv6-client, http) in favour of source-filtered rich rules. All rules for later phases (Odoo ports from lb01, 80/443/8404 on lb01) are created by the same idempotent `tools/firewall.sh` with a dead-man rollback timer.
- 2026-11-07 - app01 security update brought a new kernel and glibc, so app01 was rebooted once **before** deploying Odoo (rule 10: change requires it).
- 2026-11-07 - lb01 not updated (no repo access, B1). The RHEL 9.6 DVD is older than the installed 9.8 packages, so it can't be used for updates.

## Phase 3
- 2026-11-07 - Odoo **17.0-20260908** (`odoo:17`), PostgreSQL 16. Compose project `pca-odoo` in `/opt/pca-odoo`. Memory limits: db 512 MiB, each Odoo 800 MiB (≈2.9 GiB total, fits "about 3 GB"). `limit_memory_soft/hard` 320/480 MiB per worker so a worker is recycled before the container limit is hit.
- 2026-11-07 - **Docker bypasses firewalld for published ports** (DNAT + FORWARD; zone rich rules only filter INPUT). Measured: kali got HTTP 200 on 8069 although firewalld only allowed lb01 (`evidence/phase3/docker-firewall-bypass-before.txt`). Fix: `pca-docker-user.service` (WantedBy docker.service) fills the `DOCKER-USER` chain: allow ESTABLISHED, allow lb01 -> container ports 8069/8072 on ens160, REJECT every other NEW connection from a physical NIC. firewalld rich rules kept as defence in depth. Survives firewalld reload and docker restart (tested).
- 2026-11-07 - Ports are also bound to 192.168.100.10 only, so nothing is exposed on the NAT network (192.168.13.0/24).
- 2026-11-07 - **Docker's SELinux support was off** (containers ran as unconfined `spc_t`, `:Z` ignored). Enabled `"selinux-enabled": true` (+ `no-new-privileges`, journald logging) in `/etc/docker/daemon.json` (source `app01/daemon.json`). Containers now run as `container_t` with per-container MCS categories.
- 2026-11-07 - The shared `odoo.conf` bind mount must use **`:z`** (shared label), not `:Z` (private MCS label of the last container started): with `:Z`, 217 AVC denials on odoo.conf from the other two nodes. After the change: 0 AVC, including after a container restart.
- 2026-11-07 - With `db_name` set and the DB missing, Odoo's prefork master auto-initialises the DB with `base` only; with 3 nodes starting together this produced a broken registry (HTTP 500 on /web/health). Fix: `deploy.sh` starts the Odoo nodes only once `sale_management` is installed; `init_db.sh` drops a half-initialised DB and builds it from a one-off `docker compose run` container while the nodes are stopped.
- 2026-11-07 - Demo users `vendeur1`, `vendeur2` get "Sales / User: All Documents" (with "Own documents only" they saw 0 of the 20 demo orders), language fr_FR, timezone Africa/Tunis (same as kali). Admin password changed from the default. `web.base.url` frozen to https://odoo.pca.lab.
- 2026-11-07 - `/web/health` (Odoo 17) answers `{"status":"pass"}` without touching the database: it proves the HTTP worker is alive. DB loss is a separate risk (single PostgreSQL, see SMCA-MAPPING residual risks).
