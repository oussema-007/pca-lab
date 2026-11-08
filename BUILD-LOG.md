# BUILD-LOG — PCA mini-projet 3: Odoo HA behind a load balancer

Complete technical record of how this lab was built, tested and documented, from the first SSH check to the slide deck.

**Sources.** This log is written only from: the working session's command history and outputs, `git log -p`, the files in
`evidence/`, `DECISIONS.md`, `BLOCKERS.md`, `RESULTS.md`, and the configuration files read back over SSH from app01 and lb01
on 2026-11-08 ~02:10 (CET). Anything not confirmed by one of these is marked **[not verified]**.

**Secrets.** Every password, key, token and the load-test header (name and value) is replaced by `<see .secrets>`.
The real values live only in `~/pca-lab/.secrets` (mode 600, git-ignored) on kali. File contents below were inlined from the
repository and from the VMs through an automatic redaction filter that replaces every value found in `.secrets`.

**Dates and time zone.** Work started on 2026-11-07 ~20:27 and the last commit before this log is 2026-11-08 02:05
(kali clock, Africa/Tunis, UTC+1). Container logs are in UTC.

**Section numbering.** The requested outline jumps from 1 to 3; it is kept as requested (there is no section 2).

---

## 1. Summary

### What was built

A three-VM lab that demonstrates, with measurements, what a load balancer brings to an ERP platform covered by an ISO 22301
business-continuity management system (SMCA):

```
kali 192.168.100.30            lb01 192.168.100.20                  app01 192.168.100.10
(admin, browser, k6,   HTTPS   HAProxy 2.4.22 (RHEL RPM)            Docker CE 29.8.2, SELinux container_t
 probe, Prometheus,  ───────►  :80  -> 301 HTTPS          ───────►  odoo-1 :8069 http / :8072 websocket
 Grafana)                      :443 TLS, rate limit, HSTS           odoo-2 :8169 / :8172
                               be_odoo  (roundrobin + cookie)       odoo-3 :8269 / :8272
                               be_odoo_ws (leastconn, tunnel 1h)    pca-db          PostgreSQL 16 (primary)
                               :8404 stats + /metrics (kali only)   pca-db-replica  PostgreSQL 16 (async streaming)
                                                                    volumes: pg-data, odoo-data (shared), pg-replica
```

### Final state of each machine (read back 2026-11-08 ~02:10)

| Machine | State |
|---------|-------|
| **app01** (`192.168.100.10`, was `rhel-wazuh`) | RHEL 9.8, kernel 5.14.0-687.66.1.el9_8 (after security update + reboot), 2 vCPU, 4.8 GiB RAM, `/` 19 GB free. Boot target `multi-user.target`. SELinux Enforcing. firewalld zone `public` with no open service, rich rules only (SSH from kali, 6 Odoo ports from lb01). Docker CE 29.8.2 / Compose v5.5.1 with `selinux-enabled`, `no-new-privileges`, journald logs. `pca-docker-user.service` enabled (DOCKER-USER chain). Five containers healthy: `odoo-1`, `odoo-2`, `odoo-3` (`odoo:17`, 17.0-20260908), `pca-db`, `pca-db-replica` (`postgres:16`); replication `streaming / async`, slot `replica1` active. Wazuh stack, Groq agent, cups, avahi, cockpit socket, GUI: removed or disabled. |
| **lb01** (`192.168.100.20`, was `monitored`) | RHEL 9.8, kernel 5.14.0-687.54.1.el9_8 (not updated: no Red Hat content access, BLOCKERS B1), 2 vCPU, 1.0 GiB RAM. SELinux Enforcing, `haproxy_connect_any --> on`. firewalld: 80/443 from 192.168.100.0/24, 8404 and SSH from kali only. `haproxy-2.4.22-4.el9` and `socat-1.7.4.1-6.el9` installed from the RHEL 9.6 DVD (local repo, disabled by default). HAProxy enabled and running. Wazuh agent, nginx, postfix, `backupsvc` account, cups, avahi, cockpit socket: removed or disabled. |
| **kali** (`192.168.100.30`) | Control node and source of truth (`~/pca-lab`, git, 14 commits before this log). k6 v2.3.0 in `/usr/local/bin`. Lab CA trusted system-wide, in Firefox (enterprise policy) and in Chromium (NSS DB). `/etc/hosts` has the PCA block including `odoo.pca.lab -> 192.168.100.20`. Podman containers `pca-prometheus` (v2.55.1) and `pca-grafana` (11.3.0) running, bound to 127.0.0.1. |

### What passed and what did not

| Phase | Status | Notes |
|-------|--------|-------|
| 0 Preflight | PASS | Real values differ from the brief (RHEL 9.8 on both, RAM/disk); lb01 CDN access 403 → BLOCKERS B1 |
| 1 Cleanup | PASS | app01 free disk 2.8 GB → 23 GB; Docker empty; only sshd listening; no Wazuh process |
| 2 Hardening | PASS | sshd, firewalld (deny by default), SELinux, 189 advisories on app01, chrony; negative tests OK. lb01 not patched (B1) |
| 3 Odoo stack | PASS | after fixing: DB auto-init race, Docker bypassing firewalld, Docker SELinux disabled, `:Z` label conflict |
| 4 HAProxy | PASS | after fixing: health check needs Host header, log-format fetch, SELinux fcontext path |
| 5 Scenarios | PASS (all S1–S5) | each run ≥ 2×; one S1[stop] run reported FAIL under the first (wrong) detection metric, two S3 runs INVALID (host suspended) — all kept and explained |
| 6 Stretch | PASS | PostgreSQL streaming replica + S6 (RPO 0 observed, promotion 1.5–2.8 s); Prometheus + Grafana on kali |
| Extra | done | demo dry run (all sections OK, checklist fixed), 5-minute presentation outline, 8-slide deck |

Not achieved / limits: lb01 has no Red Hat updates (B1); a graceful `docker stop` still loses 1 in-flight probe request out of
~475 (0.21 %); scale-out gives no throughput gain on the shared 2-vCPU VM; single LB, single app VM and manual DB failover
remain single points of failure (section 8).

---

## 3. Chronological log

Conventions: `[kali]`, `[app01]`, `[lb01]` = where a command ran. From kali, VMs were reached with the SSH aliases
`app01` (user `ouss`) and `lb01` (user `monitored`) defined by the human in `~/.ssh/config`; passwordless sudo came from
`/etc/sudoers.d/90-pca` (never touched). Most remote commands were sent as `ssh -q <host> '...'` with the script on stdin.

### Phase 0 — Preflight (2026-11-07 20:27–20:31, commit `3dc7865`)

**Goal.** Verify access, record the real inventory, create `DECISIONS.md`, `BLOCKERS.md`, `.gitignore`, `.secrets`.

**Commands.**

```bash
[kali] cd ~/pca-lab && ls -la && cat ~/.ssh/config
[kali] for h in app01 lb01; do timeout 15 ssh -o BatchMode=yes $h 'sudo -n true && echo SUDO_OK; hostname'; done
[kali] sudo -n true && echo LOCAL_SUDO_OK
# -> SUDO_OK on both (hostnames rhel-wazuh, monitored), LOCAL_SUDO_OK
#    OpenSSH printed a "connection is not using a post-quantum key exchange" warning on every connection.

[kali] for h in app01 lb01; do ssh -q $h 'bash -s' < tools/inventory.sh > evidence/phase0/$h.txt; done
[kali] bash tools/inventory.sh > evidence/phase0/kali.txt
[kali] for h in app01 lb01; do ssh -q $h 'sudo ls -la /etc/ssh/sshd_config.d/; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL | grep -E "rom|sr"'; done
[lb01] sudo dnf clean all; sudo timeout 180 dnf -y --downloadonly --destdir=/tmp/dltest install haproxy
# -> Status code: 403 for https://cdn.redhat.com/content/dist/rhel9/9/x86_64/baseos/os/repodata/repomd.xml
[kali] git init -b main; umask 077; openssl rand -base64 33 | tr -dc 'A-Za-z0-9' | head -c N   # per secret, into .secrets
```

**Problems.**

1. The first attempt wrote the inventory script to the session scratchpad, which did not exist yet:
   `no such file or directory: .../scratchpad/inv.sh`. Fix: the script was put in the repo instead (`tools/inventory.sh`),
   which is also the rule (repo = source of truth).
2. `ls /etc/ssh/sshd_config.d/` → `Permission denied` without sudo (directory mode 700). Fix: `sudo ls` / `sudo sh -c`.
3. lb01 `subscription-manager status`: *Consumer profile "<redacted-consumer-id>" has been deleted from the server*; dnf metadata
   download → HTTP 403. Rule 4 forbids registration → **BLOCKERS B1**. Workaround chosen: the RHEL 9.6 DVD already attached
   to lb01 as `/dev/sr1` (found with `lsblk`) used as a local repo in phase 4.

**Files created.** `tools/inventory.sh` (read-only inventory), `.gitignore`, `.secrets` (11 keys at that time:
`ODOO_ADMIN_PASSWD`, `POSTGRES_PASSWORD`, `ODOO_DB_ADMIN_LOGIN`, `ODOO_DB_ADMIN_PASSWORD`, `VENDEUR1_PASSWORD`,
`VENDEUR2_PASSWORD`, `HAPROXY_STATS_USER`, `HAPROXY_STATS_PASSWORD`, `LOADTEST_HEADER_NAME`, `LOADTEST_HEADER_VALUE`,
`REPL_PASSWORD`; `GRAFANA_ADMIN_PASSWORD` was added in phase 6), `evidence/phase0/inventory.md`, `DECISIONS.md`,
`BLOCKERS.md`. Secrets: 16–32 alphanumeric characters from `openssl rand`.

**`tools/inventory.sh`**

```bash
#!/bin/bash
# Read-only inventory of a lab host. Usage: ssh host 'bash -s' < tools/inventory.sh
echo "### hostname"; hostname
echo "### ip -br addr"; ip -br addr
echo "### ip route"; ip route
echo "### release"; cat /etc/redhat-release 2>/dev/null || head -3 /etc/os-release
echo "### uname"; uname -r
echo "### nproc"; nproc
echo "### lscpu"; lscpu | grep -E 'Model name|^CPU\(s\)'
echo "### free -h"; free -h
echo "### df -h"; df -h
echo "### selinux"; getenforce 2>/dev/null || echo n/a
echo "### firewalld"; systemctl is-active firewalld; sudo firewall-cmd --get-default-zone 2>/dev/null; sudo firewall-cmd --list-all 2>/dev/null
echo "### docker"; sudo docker version --format 'server {{.Server.Version}}' 2>&1 | head -2; sudo docker compose version 2>&1 | head -1
echo "### subscription"; sudo subscription-manager status 2>&1 | head -8
echo "### dnf repolist"; sudo timeout 120 dnf -q repolist 2>&1 | head -15
echo "### curl registry"; timeout 20 curl -sSI https://registry-1.docker.io/v2/ 2>&1 | head -1
echo "### sshd_config.d"; ls -l /etc/ssh/sshd_config.d/ 2>&1
echo "### default target"; systemctl get-default
echo "### listening"; sudo ss -tlnp
```

`.gitignore` (final version, lines were appended in phases 4 and 5):

**`.gitignore`**

```text
.secrets
pki/*.key
pki/private/
*.key
results/raw/*.tmp
pki/*.pem
results/raw/.s4.*
```

**Verification (actual output, `evidence/phase0/inventory.md`).**

**`evidence/phase0/inventory.md (lines 1-44)`**

```text
# Phase 0 - Inventory (collected 2026-11-07 from kali)

Raw output: `app01.txt`, `lb01.txt`, `kali.txt` in this directory (produced by `tools/inventory.sh`).

| Name | Hostname found | SSH user | Lab IP | NAT IP | OS (real) | vCPU | RAM | Root FS | SELinux | firewalld | Docker |
|------|----------------|----------|--------|--------|-----------|------|-----|---------|---------|-----------|--------|
| app01 | rhel-wazuh | ouss | 192.168.100.10 (ens160) | 192.168.13.136 (**ens224**) | **RHEL 9.8** | 2 | **4.8 GiB** + 5 GiB swap | 44G, **2.8G free (94 %)** | Enforcing | active, zone public, ports 443,1514,1515 open | Docker CE 29.8.2, Compose v5.5.1 |
| lb01 | monitored | monitored | 192.168.100.20 (ens160) | 192.168.13.138 (ens192) | **RHEL 9.8** | 2 | **1.0 GiB** + 2 GiB swap | 22G, 16G free | Enforcing | active, zone public, http open | none |
| kali | kali | kali | 192.168.100.30 (eth0) | 192.168.13.137 (eth1) | Kali Rolling 2026.1 | 2 | 3.6 GiB | 79G, 33G free | n/a | inactive | podman (docker CLI emulation) |

CPU on all three: 13th Gen Intel Core i7-13620H (VMware vCPU).

## Access
- `ssh app01 'sudo -n true'`, `ssh lb01 'sudo -n true'`, local `sudo -n true`: all OK.
- `/etc/ssh/sshd_config.d/00-temp-pass.conf`: **absent** on app01 and lb01 (nothing to remove).
- Effective sshd (both VMs): PermitRootLogin no, PasswordAuthentication no, MaxAuthTries 6, X11Forwarding yes.
- lb01 has an extra LogSentinel drop-in `60-logsentinel-victim.conf` (`Match User backupsvc` -> PasswordAuthentication yes): removed in Phase 1.

## Disk (`df -h`, the "low disk space" alert source)
- app01 `/` is at 94 % (2.8G free). This is the machine that raised the alert. Also mounted: two optical media (CDROM 168M, RHEL 9.6 DVD 12G) that always show 100 %, which is normal.
- lb01 `/` 29 %, kali `/` 57 %. No other filesystem above 50 %.

## Subscriptions / internet
- app01: Registered (SCA). `dnf repolist`: BaseOS, AppStream, docker-ce-stable. Works.
- lb01: `subscription-manager status` -> "Consumer profile ... has been deleted from the server". `dnf` metadata download returns **HTTP 403** from cdn.redhat.com. See BLOCKERS.md B1.
- `curl -I https://registry-1.docker.io/v2/` -> HTTP/2 401 (reachable) from all three.
- lb01 has the RHEL 9.6 BaseOS DVD in its virtual drive (`/dev/sr1`, unmounted); app01 has it mounted.

## Boot target
- app01: graphical.target (fixed in Phase 1/2 to multi-user.target to save RAM). lb01: multi-user.target. 

## Listening sockets at start
- app01: sshd :22, cupsd 127.0.0.1:631.
- lb01: sshd :22, nginx :80, postfix 127.0.0.1:25, cupsd 127.0.0.1:631.
```

### Phase 1 — Clean up the old LogSentinel project (20:31–20:36, commit `973bddc`)

**Goal.** Free disk on app01 first, remove the Wazuh stack, the Groq AI agent and its secrets, the Wazuh agent and old
demo services on lb01, set hostnames and `/etc/hosts`.

**Commands — app01 Docker and disk.**

```bash
[app01] df -h /; sudo docker ps -a; sudo docker compose ls -a; sudo docker images; sudo docker volume ls; sudo docker system df
# -> project "single-node" at /home/ouss/wazuh-docker/single-node/docker-compose.yml, 3 exited containers,
#    images 7.04 GB, 14 volumes 12.42 GB, / 2.8 GB free (94 %)          (evidence/phase1/app01-before.txt)
[app01] cd /home/ouss/wazuh-docker/single-node && sudo docker compose down -v --rmi all --remove-orphans
[app01] sudo docker volume ls -q | grep -iE "wazuh|single-node|filebeat" | xargs -r sudo docker volume rm
[app01] sudo docker network ls -q --filter name=single-node | xargs -r sudo docker network rm
[app01] sudo docker system prune -a --volumes -f          # "Total reclaimed space: 432.6MB" (hello-world + certs-generator)
[app01] sudo rm -rf /home/ouss/wazuh-docker; sudo dnf clean all -q; sudo journalctl --vacuum-size=200M
[app01] df -h /   # -> 44G size, 21G used, 23G avail (48 %)
```

**Commands — locating leftovers (names only, contents never displayed).**

```bash
[both] systemctl list-unit-files | grep -iE "wazuh|groq|logsentinel|...|nginx|httpd|postfix|dovecot|..."
[both] sudo find / -xdev \( -iname "*groq*" -o -iname "*logsentinel*" -o -iname "*wazuh*" -o -iname "*ossec*" -o -iname "*scoring*" \) ...
[both] sudo grep -rlIs -i groq /home /root /opt /etc /srv /usr/local
[both] sudo grep -lsIE "GROQ|gsk_[A-Za-z0-9]{10}|_API_KEY" /home/*/.bashrc /home/*/.bash_profile ... /etc/environment /etc/profile.d/*
# -> no API key in any shell/environment file; agent = /home/ouss/logsentinel-ai (ai_agent.py, root-ca.pem, __pycache__, venv)
```

**Commands — app01 removal.**

```bash
[app01] cd /home/ouss
for d in logsentinel-ai cert-backup-2026-10-02 cert-build; do
  sudo find "$d" -path "*/venv" -prune -o -type f -exec shred -u {} +      # agent code + old CA / Wazuh private keys
done
sudo rm -rf logsentinel-ai cert-backup-2026-10-02 cert-build local_rules.xml.bak-2026-10-04 .cache/pip
sudo cp -a /etc/sysctl.d/99-wazuh.conf /root/pca-backup/ && sudo rm -f /etc/sysctl.d/99-wazuh.conf
rpm -q wazuh-agent || echo "no wazuh-agent rpm"                         # -> not installed on app01
for p in 443/tcp 1514/tcp 1515/tcp 55000/tcp 9200/tcp; do sudo firewall-cmd -q --permanent --remove-port=$p; done
sudo firewall-cmd -q --reload
```

**Commands — lb01 removal.**

```bash
[lb01] sudo systemctl disable --now wazuh-agent nginx postfix
sudo cp -a /var/ossec/etc/ossec.conf /root/pca-backup/ossec.conf
sudo cp -a /etc/ssh/sshd_config.d/60-logsentinel-victim.conf /etc/yum.repos.d/wazuh.repo /root/pca-backup/
sudo rpm -e wazuh-agent           # warning: /var/ossec/etc/client.keys saved as /var/ossec/etc/client.keys.rpmsave
sudo dnf -y -q --disablerepo="*" remove nginx nginx-core nginx-filesystem postfix   # also removed redhat-logos-httpd
sudo rm -rf /var/ossec /etc/yum.repos.d/wazuh.repo /var/cache/dnf/wazuh-* /etc/systemd/system/nginx.service.d \
            /home/ouss/ossec.conf.bak-2026-10-04 /usr/share/nginx /var/log/nginx
sudo semodule -l | grep -q wazuh && sudo semodule -r wazuh
sudo rm -f /etc/ssh/sshd_config.d/60-logsentinel-victim.conf   # "Match User backupsvc / PasswordAuthentication yes"
sudo pkill -u backupsvc; sudo userdel -r backupsvc              # LogSentinel brute-force victim account
sudo sshd -t && sudo systemctl reload sshd                      # SSHD_RELOADED, then a new ssh session -> STILL_REACHABLE
for s in http https smtp; do sudo firewall-cmd -q --permanent --remove-service=$s; done; sudo firewall-cmd -q --reload
```

Note: `client.keys.rpmsave` (Wazuh agent registration key) was deleted with `rm -rf /var/ossec`, not with `shred`
(the Groq key files and private keys on app01 were shredded).

**Commands — hostnames, hosts, services.**

```bash
[kali] for h in app01 lb01; do scp tools/set_hosts.sh $h:/tmp/ && ssh -q $h "sudo bash /tmp/set_hosts.sh && \
         sudo hostnamectl set-hostname $h && sudo systemctl disable --now cups cups.socket cups.path; \
         sudo systemctl set-default multi-user.target"; done
[app01] sudo systemctl isolate multi-user.target     # GDM stopped live; available RAM 3.4 GiB -> 4.1 GiB
[kali] sudo bash tools/set_hosts.sh with-vip         # adds odoo.pca.lab -> 192.168.100.20
[both] sudo systemctl disable --now avahi-daemon.socket avahi-daemon.service   # was still announcing rhel-wazuh.local
```

**`tools/set_hosts.sh`**

```bash
#!/bin/bash
# Idempotent: (re)writes a marked PCA block in /etc/hosts, drops old wazuh names.
# Usage: sudo bash set_hosts.sh [with-vip]   (with-vip adds odoo.pca.lab -> lb01, used on kali)
set -euo pipefail
F=/etc/hosts
mkdir -p /root/pca-backup 2>/dev/null || true
[ -f /root/pca-backup/hosts.orig ] || cp -a $F /root/pca-backup/hosts.orig 2>/dev/null || true
tmp=$(mktemp)
sed '/# BEGIN PCA-LAB/,/# END PCA-LAB/d' $F | grep -viE 'wazuh|logsentinel' > "$tmp" || true
{
  echo "# BEGIN PCA-LAB (managed by ~/pca-lab/tools/set_hosts.sh)"
  echo "192.168.100.10 app01 app01.pca.lab"
  echo "192.168.100.20 lb01 lb01.pca.lab"
  echo "192.168.100.30 kali kali.pca.lab"
  [ "${1:-}" = with-vip ] && echo "192.168.100.20 odoo.pca.lab"
  echo "# END PCA-LAB"
} >> "$tmp"
cat "$tmp" > $F; rm -f "$tmp"
```

Line by line: the block between `# BEGIN PCA-LAB` and `# END PCA-LAB` is deleted and rewritten on every run (idempotent);
any line containing `wazuh` or `logsentinel` is dropped (removed `127.0.0.1 wazuh.indexer` on app01); other lines are kept
(kali's entries from unrelated labs were left untouched); the original is saved once to `/root/pca-backup/hosts.orig`.

**Problems.**

1. The first verification used `pgrep -af "wazuh|ossec"`, which matched its own `bash -c` command line and printed
   false positives. Fix: `tools/verify_phase1.sh`, which inspects process names (`ps -eo pid,comm,args`).
2. `avahi-daemon` was still announcing the old name `rhel-wazuh.local`. Fix: disabled (mDNS not needed on servers).

**Not removed (deliberately).** `/home/ouss/dfir-wk0`, `/home/ouss/dfir-wk0-vault` (contain a folder `07-wazuh` of DFIR
evidence) and `/home/ouss/amir-s0-package*` on app01: other coursework, not LogSentinel.

**Verification (actual output, `evidence/phase1/verify.txt`, abbreviated by grep at the time).**

**`evidence/phase1/verify.txt (lines 1-60)`**

```text
======== app01
-- app01 2026-11-07T20:36:37+01:00 default target: multi-user.target
Filesystem             Size  Used Avail Use% Mounted on
/dev/mapper/rhel-root   44G   21G   23G  48% /
-- docker ps -a
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
-- ss -tlnp
State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess                        
LISTEN 0      128          0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=1136,fd=7))
LISTEN 0      128             [::]:22           [::]:*    users:(("sshd",pid=1136,fd=8))
-- wazuh/ossec/groq processes (by command name):
(end)
-- leftover packages:
none
-- firewalld: services=cockpit dhcpv6-client ssh ports=
======== lb01
-- lb01 2026-11-07T20:36:40+01:00 default target: multi-user.target
Filesystem             Size  Used Avail Use% Mounted on
/dev/mapper/rhel-root   22G  5.5G   16G  26% /
-- docker ps -a
docker not installed
-- ss -tlnp
State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess                        
LISTEN 0      128          0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=1007,fd=7))
LISTEN 0      128             [::]:22           [::]:*    users:(("sshd",pid=1007,fd=8))
-- wazuh/ossec/groq processes (by command name):
(end)
-- leftover packages:
none
-- firewalld: services=cockpit dhcpv6-client ssh ports=
======== kali: wazuh procs
none
```

### Phase 2 — Baseline hardening (20:36–20:53, commit `1c42e4b`)

**Goal.** SELinux enforcing, restrictive firewalld, hardened sshd, security updates, time sync; document each step.

**sshd.** Observed first: effective `MaxAuthTries 6` and `X11Forwarding yes` although `99-logsentinel.conf` existed.
Cause: sshd keeps the **first** value it reads, files in `sshd_config.d` are included in alphabetical order, and
`50-redhat.conf` sets `X11Forwarding yes`. Fix: a drop-in named `01-…`.

**`common/01-pca-hardening.conf`**

```text
# PCA lab sshd hardening - deployed from ~/pca-lab/common/01-pca-hardening.conf
# Named 01- so it is read BEFORE 50-redhat.conf: for sshd the first value wins.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

**`tools/harden_sshd.sh`**

```bash
#!/bin/bash
# Idempotent sshd hardening. Run on a VM as root. Key login was verified from kali before running.
set -euo pipefail
SRC=/tmp/01-pca-hardening.conf
D=/etc/ssh/sshd_config.d
mkdir -p /root/pca-backup/sshd_config.d
cp -an $D/. /root/pca-backup/sshd_config.d/ 2>/dev/null || true
install -m 600 -o root -g root $SRC $D/01-pca-hardening.conf
rm -f $D/99-logsentinel.conf          # superseded (old LogSentinel file, backed up)
restorecon -F $D/01-pca-hardening.conf
if sshd -t; then systemctl reload sshd; echo "sshd reloaded"; else
  echo "sshd -t FAILED, restoring"; rm -f $D/01-pca-hardening.conf; cp -a /root/pca-backup/sshd_config.d/99-logsentinel.conf $D/ 2>/dev/null; exit 1; fi
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries|x11forwarding|allowtcpforwarding|logingracetime) '
```

```bash
[kali] for h in app01 lb01; do scp -q common/01-pca-hardening.conf tools/harden_sshd.sh $h:/tmp/ && \
         ssh -q $h 'sudo bash /tmp/harden_sshd.sh; rm -f /tmp/harden_sshd.sh /tmp/01-pca-hardening.conf'; \
         ssh -q -o ConnectTimeout=5 $h 'echo NEW_SSH_SESSION_OK'; done
```

Key login had been proven before (all previous commands used the key). `sshd -t` runs before the reload; on failure the script
restores the previous drop-in.

**firewalld.** One idempotent script with two actions. `apply` arms a 120 s rollback timer
(`systemd-run --on-active=120 firewall-cmd --reload`, which would restore the untouched permanent config), adds the SSH-from-kali
rule **first**, then the other rules, then removes every world-open service and port — runtime only. `commit` (sent over a
**new** SSH connection, proving access still works) runs `--runtime-to-permanent` and stops the timer.

**`tools/firewall.sh`**

```bash
#!/bin/bash
# Idempotent firewalld policy for the PCA lab. Usage (as root on the VM): firewall.sh app01|lb01 {apply|commit}
#  apply : add the SSH-from-kali rule first, then the rest, RUNTIME ONLY, arm a 120 s rollback timer
#  commit: (called from kali over a NEW ssh session) persist runtime -> permanent, cancel the timer
set -euo pipefail
ROLE=$1; ACTION=$2
KALI=192.168.100.30; LB=192.168.100.20; LAN=192.168.100.0/24
Z=public
if [ "$ACTION" = commit ]; then
  firewall-cmd --runtime-to-permanent
  systemctl stop pca-fw-rollback.timer 2>/dev/null || true
  echo "committed"; firewall-cmd --zone=$Z --list-all; exit 0
fi
mkdir -p /root/pca-backup; [ -f /root/pca-backup/firewalld-public.xml ] || cp -a /etc/firewalld/zones/public.xml /root/pca-backup/firewalld-public.xml 2>/dev/null || true
systemctl stop pca-fw-rollback.timer 2>/dev/null || true
systemd-run --quiet --unit=pca-fw-rollback --on-active=120 /usr/bin/firewall-cmd --reload
firewall-cmd --set-default-zone=$Z >/dev/null 2>&1 || true
rr(){ firewall-cmd -q --zone=$Z --add-rich-rule="$1" 2>/dev/null || true; }
# 1) SSH from kali only (added BEFORE removing the open ssh service)
rr "rule family=ipv4 source address=$KALI service name=ssh accept"
if [ "$ROLE" = app01 ]; then
  for p in 8069 8072 8169 8172 8269 8272; do rr "rule family=ipv4 source address=$LB port port=$p protocol=tcp accept"; done
fi
if [ "$ROLE" = lb01 ]; then
  rr "rule family=ipv4 source address=$LAN service name=http accept"
  rr "rule family=ipv4 source address=$LAN service name=https accept"
  rr "rule family=ipv4 source address=$KALI port port=8404 protocol=tcp accept"
fi
# 2) close everything that was open to the world
for s in ssh cockpit dhcpv6-client http https; do firewall-cmd -q --zone=$Z --remove-service=$s 2>/dev/null || true; done
for p in $(firewall-cmd --zone=$Z --list-ports); do firewall-cmd -q --zone=$Z --remove-port=$p; done
echo "runtime applied; rollback in 120 s unless committed"
```

```bash
[kali] for h in app01 lb01; do scp -q tools/firewall.sh $h:/tmp/pca-firewall.sh && \
  ssh -q $h "sudo install -m 700 /tmp/pca-firewall.sh /usr/local/sbin/pca-firewall.sh && sudo /usr/local/sbin/pca-firewall.sh $h apply" && \
  ssh -q -o ConnectTimeout=8 $h "sudo /usr/local/sbin/pca-firewall.sh $h commit"; done
# -> "runtime applied; rollback in 120 s unless committed" / "success" / "committed"; timer inactive afterwards
```

Rules for later phases (Odoo ports from lb01, 80/443/8404 on lb01) were created here, in the same script.

**Updates.**

```bash
[app01] sudo dnf -q updateinfo list --security | wc -l     # 189 advisories (kernel, glibc, openssh, openssl, sudo, curl, ...)
[app01] sudo dnf -y update --security                      # Complete!
[app01] sudo dnf -q needs-restarting -r                    # glibc, kernel -> "Reboot is required", rc=1
[app01] sudo systemctl disable --now cockpit.socket; sudo systemctl reboot     # (cockpit.socket also disabled on lb01)
[kali] wait loop -> "UP 5.14.0-687.66.1.el9_8.x86_64 up 0 minutes"
```

Problem: the first `updateinfo` call ran > 200 s (full metadata download after `dnf clean all` in phase 1) and was moved to the
background; its output was cut. It was re-run once the cache existed. lb01: not updated (B1; the 9.6 DVD is older than the
installed 9.8 packages).

**Time sync.** chronyd active on both, offsets 10–160 µs (`chronyc tracking`); kali uses systemd-timesyncd
(`NTPSynchronized=yes`).

**Negative tests.** `nc -vz -s 192.168.13.137 …` produced no output on Kali's `nc` variant; replaced by
`curl --interface 192.168.13.137 telnet://<NAT IP>:22` → `Failed to connect … after 3 ms` (REJECT).

**Verification (actual output, `evidence/phase2/verify.txt`).**

**`evidence/phase2/verify.txt`**

```text
== app01 2026-11-07T20:52:59+01:00 kernel 5.14.0-687.66.1.el9_8.x86_64
-- SELinux: Enforcing (config: SELINUX=enforcing)
-- firewalld: active, default zone public
  services: 
  ports: 
  forward-ports: 
  source-ports: 
  rich rules: 
	rule family="ipv4" source address="192.168.100.30" service name="ssh" accept
	rule family="ipv4" source address="192.168.100.20" port port="8269" protocol="tcp" accept
	rule family="ipv4" source address="192.168.100.20" port port="8272" protocol="tcp" accept
	rule family="ipv4" source address="192.168.100.20" port port="8072" protocol="tcp" accept
	rule family="ipv4" source address="192.168.100.20" port port="8169" protocol="tcp" accept
	rule family="ipv4" source address="192.168.100.20" port port="8069" protocol="tcp" accept
	rule family="ipv4" source address="192.168.100.20" port port="8172" protocol="tcp" accept
-- sshd effective:
logingracetime 30
maxauthtries 3
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
x11forwarding no
allowtcpforwarding no
-- chrony: active
Reference ID    : C40A343A (ntp4.inx.net.za)
System time     : 0.000164158 seconds slow of NTP time
Leap status     : Normal
-- disabled services:
   cups: disabled/inactive
   avahi-daemon: disabled/inactive
   cockpit.socket: disabled/inactive
-- default target: multi-user.target
-- listening:
   0.0.0.0:22
   [::]:22
== lb01 2026-11-07T20:53:02+01:00 kernel 5.14.0-687.54.1.el9_8.x86_64
-- SELinux: Enforcing (config: SELINUX=enforcing)
-- firewalld: active, default zone public
  services: 
  ports: 
  forward-ports: 
  source-ports: 
  rich rules: 
	rule family="ipv4" source address="192.168.100.0/24" service name="http" accept
	rule family="ipv4" source address="192.168.100.30" port port="8404" protocol="tcp" accept
	rule family="ipv4" source address="192.168.100.30" service name="ssh" accept
	rule family="ipv4" source address="192.168.100.0/24" service name="https" accept
-- sshd effective:
logingracetime 30
maxauthtries 3
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
x11forwarding no
allowtcpforwarding no
-- chrony: active
Reference ID    : 66CDF001 (flapping.cloudhive.net.za)
System time     : 0.000053501 seconds fast of NTP time
Leap status     : Normal
-- disabled services:
   cups: disabled/inactive
   avahi-daemon: disabled/inactive
   cockpit.socket: disabled/inactive
-- default target: multi-user.target
-- listening:
   0.0.0.0:22
   [::]:22
== negative test: password auth refused
Permission denied (publickey,gssapi-keyex,gssapi-with-mic).
== negative test: root login refused
Permission denied (publickey,gssapi-keyex,gssapi-with-mic).
== negative test: SSH to app01 NAT IP from kali NAT IP (not 192.168.100.30) must be rejected
== negative test: TCP/22 from kali's NAT address 192.168.13.137 (not in the allow-list)
$ curl --interface 192.168.13.137 telnet://192.168.13.136:22
curl: (7) Failed to connect to 192.168.13.136 port 22 after 3 ms: Could not connect to server
$ curl --interface 192.168.13.137 telnet://192.168.13.138:22
curl: (7) Failed to connect to 192.168.13.138 port 22 after 5 ms: Could not connect to server
```

The jury-facing list with justifications is `evidence/phase2/hardening.md`.

### Phase 3 — Odoo stack on app01 (20:53–21:16, commit `90f6a7f`)

**Goal.** 3 × Odoo 17 + PostgreSQL 16 in Docker Compose under `/opt/pca-odoo`, shared filestore/sessions, DB not published,
ports bound to the lab IP and reachable only from lb01, DB `pca_demo` with sales demo data and two users.

**Images** (pulled in the background during phase 2): `postgres:16` (637 MB), `odoo:17` (2.71 GB).
Image inspection: user `odoo` = uid/gid 101, `Odoo Server 17.0-20260908`, `/web/health` route present
(`auth='none'`, `{"status": "pass"}`, optional `db_server_status`), `curl` present in the image.

**Files.** `app01/docker-compose.yml`, `app01/config/odoo.conf.tpl`, `app01/deploy.sh`, `app01/init_db.sh`,
`app01/scripts/pca-docker-user.sh` + `.service`, `app01/daemon.json`, `tools/check_phase3.sh` (full contents in section 4).

**Problem 1 — HTTP 500 on odoo-2/odoo-3 at first start.**
`deploy.sh` (first version) ran `docker compose up -d` for all services. odoo-1 became healthy; odoo-2 and odoo-3 stayed
unhealthy. `docker logs odoo-2`:
```
KeyError: 'ir.http'
... "GET /web/health HTTP/1.1" 500
```
`psql`: database `pca_demo` existed with 114 tables; odoo-1's log showed `init db` / `Loading module base`.
Cause: with `db_name` set and the database missing, Odoo's prefork master initialised it with `base` only, while the two
other nodes loaded a half-built registry. Fix: `deploy.sh` now starts only `db`, checks that `sale_management` is installed,
and only then starts the Odoo nodes (else prints `NEED_INIT`); `init_db.sh` stops the nodes, drops a half-initialised DB and
builds it from a one-off container (`docker compose run --rm --no-deps odoo-1 odoo … -i sale_management
--load-language=fr_FR --stop-after-init --no-http --workers=0 --max-cron-threads=0`).
Result: `Registry loaded in 166.646s`, `COUNTS sale.order=20 res.partner=38 product=34 demo=True`, users vendeur1/vendeur2 created.

**Problem 2 — Docker bypasses firewalld.** From kali, `curl http://192.168.100.10:8069/web/health` returned **200** on all
published ports although firewalld only allowed lb01 (`evidence/phase3/docker-firewall-bypass-before.txt`).
`docker info`: `Firewall Backend: iptables+firewalld`; `iptables -S FORWARD`: `-P FORWARD DROP`, `-A FORWARD -j DOCKER-USER`.
Cause: published ports are DNATed and forwarded; firewalld zone rules filter INPUT only.
Fix: `pca-docker-user.service` fills the `DOCKER-USER` chain (Docker never writes to it). After: kali `Failed to connect …`
on all six ports, lb01 200; rules survived `firewall-cmd --reload` and `systemctl restart docker` (3 `pca` rules each time).

**Problem 3 — demo users saw 0 sales orders.** `search_count` on `sale.order` returned 0 for vendeur1 (group
"User: Own Documents Only"). Fix: `sales_team.group_sale_salesman_all_leads` in `init_db.sh`, re-run → 20.

**Problem 4 — `ausearch` hung**, because it reads stdin when it is not a TTY. Fix: `ausearch --input-logs … </dev/null`.
A following `pkill -f "ausearch -m avc"` matched its own SSH command line and killed the session (no damage; the DECISIONS
append in that command did not run and was redone).

**Problem 5 — containers were not confined by SELinux.** `ps -eZ` showed `spc_t` and `odoo.conf` kept `usr_t` despite `:Z`:
`docker info` had no `name=selinux`. Fix: `/etc/docker/daemon.json` with `"selinux-enabled": true` (plus
`no-new-privileges`, journald) and `docker restart`; processes became `container_t:s0:cX,cY`.

**Problem 6 — `:Z` on a file shared by three containers.** After enabling SELinux: 159 then 217 AVC denials, all
`name="odoo.conf"` (`comm="python3"/"grep"/"odoo"`), labels with three different MCS pairs. Cause: `:Z` gives the file the
private label of the last container that mounted it. Fix: `:z` (shared label `container_file_t:s0`). After the recreate the
last AVC was at 21:13:09 and there were 0 denials afterwards, including after `docker restart odoo-2`.

**Verification (actual output, `evidence/phase3/checks.txt` and `selinux.txt`).**

**`evidence/phase3/checks.txt`**

```text
### 2026-11-07T21:15:28+01:00 health from lb01 (allowed)
GET http://192.168.100.10:8069/web/health -> {"status": "pass"} HTTP 200
GET http://192.168.100.10:8169/web/health -> {"status": "pass"} HTTP 200
GET http://192.168.100.10:8269/web/health -> {"status": "pass"} HTTP 200
### health from kali (must be refused)
kali -> 192.168.100.10:8069 : curl: (7) Failed to connect to 192.168.100.10 port 8069 after 1 ms: Could not connect to server
kali -> 192.168.100.10:8169 : curl: (7) Failed to connect to 192.168.100.10 port 8169 after 0 ms: Could not connect to server
kali -> 192.168.100.10:8269 : curl: (7) Failed to connect to 192.168.100.10 port 8269 after 0 ms: Could not connect to server
kali -> 192.168.100.10:8072 : curl: (7) Failed to connect to 192.168.100.10 port 8072 after 0 ms: Could not connect to server
kali -> 192.168.100.10:8172 : curl: (7) Failed to connect to 192.168.100.10 port 8172 after 0 ms: Could not connect to server
kali -> 192.168.100.10:8272 : curl: (7) Failed to connect to 192.168.100.10 port 8272 after 0 ms: Could not connect to server
### PostgreSQL not published: 0 listeners on :5432 on the host
### login as vendeur1 on each node (from lb01) + search_read sale.order
port 8069: authenticate -> uid/name = 8 Vendeur 1 ; sale.order count visible = 20
port 8169: authenticate -> uid/name = 8 Vendeur 1 ; sale.order count visible = 20
port 8269: authenticate -> uid/name = 8 Vendeur 1 ; sale.order count visible = 20
### session shared between nodes: login on odoo-1, reuse cookie on odoo-3
session from 8069 used on 8169 -> uid 8 vendeur1
session from 8069 used on 8269 -> uid 8 vendeur1
### containers
NAMES     STATUS                        PORTS
odoo-3    Up 2 minutes (healthy)        8071/tcp, 192.168.100.10:8269->8069/tcp, 192.168.100.10:8272->8072/tcp
odoo-1    Up 2 minutes (healthy)        192.168.100.10:8069->8069/tcp, 192.168.100.10:8072->8072/tcp, 8071/tcp
odoo-2    Up About a minute (healthy)   8071/tcp, 192.168.100.10:8169->8069/tcp, 192.168.100.10:8172->8072/tcp
pca-db    Up 4 minutes (healthy)        5432/tcp
NAME      MEM USAGE / LIMIT   CPU %
odoo-3    308.6MiB / 800MiB   8.53%
odoo-1    370.8MiB / 800MiB   0.00%
odoo-2    304.3MiB / 800MiB   1.19%
pca-db    76.25MiB / 512MiB   12.44%
               total        used        free      shared  buff/cache   available
Mem:           4.8Gi       1.9Gi       2.1Gi        38Mi       1.1Gi       2.9Gi
```

**`evidence/phase3/selinux.txt`**

```text
SELinux: Enforcing
docker security options: [name=seccomp,profile=builtin name=selinux name=cgroupns name=no-new-privileges]
process labels:
     25 system_u:system_r:container_t:s0:c126,c989
      4 system_u:system_r:container_t:s0:c245,c579
      4 system_u:system_r:container_t:s0:c269,c797
      4 system_u:system_r:container_t:s0:c485,c554
system_u:object_r:container_file_t:s0 /opt/pca-odoo/config/odoo.conf
AVC denials in last 10 min: 217 (all from BEFORE the :Z -> :z fix, all on odoo.conf, see DECISIONS.md)
Last AVC denial timestamp: 21:13:09 (during the :Z->:z recreate). AVC denials since 21:13:43: 0 (checked at 21:16:13, includes the phase-3 check run)
```

### Phase 4 — HAProxy on lb01 (21:16–21:25, commits `b0ed505`, `d018f6b`)

**Goal.** HAProxy from the RHEL package, local CA and TLS, HTTP→HTTPS, rate limit with exemption, health checks, cookie
persistence, websocket backend, stats, runtime API, logging, SELinux, firewall.

**Install.** `lb01/install_haproxy.sh` mounts `/dev/sr1` read-only on `/mnt/rhel-dvd`, writes a disabled repo file and runs
`dnf --disablerepo='*' --enablerepo='rhel-dvd-*' install haproxy socat` with `gpgcheck=1`.
Output: `haproxy-2.4.22-4.el9.x86_64`, signature `RSA/SHA256, Tue 07 Jan 2025 …, Key ID 199e2f91fd431d51`;
`haproxy -vv`: `USE_OPENSSL=1 USE_LUA=1 … USE_PROMEX=1`, built with OpenSSL 3.2.2, running on OpenSSL 3.5.8.
Problem: the first version ended with `rpm -K /mnt/rhel-dvd/AppStream/Packages/h/haproxy-*.rpm` (wrong path), which failed
under `set -e` before `umount`. Fix: signature read from the installed package, unmount in both branches. `socat` (needed for
the admin socket) was added later the same way.

**`lb01/install_haproxy.sh`**

```bash
#!/bin/bash
# Idempotent: install the Red Hat haproxy RPM on lb01 from the RHEL DVD attached to the VM (CDN access is blocked, BLOCKERS B1).
set -euo pipefail
if rpm -q haproxy socat >/dev/null; then echo "haproxy already installed: $(rpm -q haproxy)"; rpm -q --qf "signature: %{SIGPGP:pgpsig}\n" haproxy; mountpoint -q /mnt/rhel-dvd && umount /mnt/rhel-dvd; exit 0; fi
mkdir -p /mnt/rhel-dvd
mountpoint -q /mnt/rhel-dvd || mount -o ro /dev/sr1 /mnt/rhel-dvd
cat > /etc/yum.repos.d/rhel-dvd.repo <<R
[rhel-dvd-baseos]
name=RHEL 9.6 DVD BaseOS (local, read-only)
baseurl=file:///mnt/rhel-dvd/BaseOS
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
[rhel-dvd-appstream]
name=RHEL 9.6 DVD AppStream (local, read-only)
baseurl=file:///mnt/rhel-dvd/AppStream
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
R
dnf -y --disablerepo='*' --enablerepo='rhel-dvd-*' install haproxy socat
rpm -q haproxy; rpm -q --qf "signature: %{SIGPGP:pgpsig}\n" haproxy
umount /mnt/rhel-dvd
```

**PKI** (kali): `pki/make_pki.sh` — EC P-256 CA "PCA Lab Root CA" (825 days, `pathlen:0`), server certificate for
`odoo.pca.lab` (397 days, `serverAuth`, SAN `DNS:odoo.pca.lab, DNS:lb01.pca.lab, IP:192.168.100.20`), HAProxy bundle
`odoo.pca.lab.pem` = cert + CA + key (git-ignored). Trust on kali:
`sudo install -m 644 pki/ca.crt /usr/local/share/ca-certificates/pca-lab-ca.crt && sudo update-ca-certificates`.

**`pki/make_pki.sh`**

```bash
#!/bin/bash
# Idempotent local PKI: CA (stays on kali) + server cert for odoo.pca.lab (SAN DNS + IP of lb01).
set -euo pipefail
cd "$(dirname "$0")"
umask 077
if [ ! -f ca.key ]; then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 825 -subj "/C=TN/O=PCA Lab/CN=PCA Lab Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.crt
fi
if [ ! -f odoo.pca.lab.crt ] || ! openssl x509 -checkend 2592000 -noout -in odoo.pca.lab.crt; then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out odoo.pca.lab.key
  openssl req -new -key odoo.pca.lab.key -subj "/C=TN/O=PCA Lab/CN=odoo.pca.lab" -out odoo.pca.lab.csr
  cat > server.ext <<X
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:odoo.pca.lab,DNS:lb01.pca.lab,IP:192.168.100.20
X
  openssl x509 -req -in odoo.pca.lab.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 397 -sha256 -extfile server.ext -out odoo.pca.lab.crt
  rm -f odoo.pca.lab.csr
fi
cat odoo.pca.lab.crt ca.crt odoo.pca.lab.key > odoo.pca.lab.pem   # HAProxy bundle: cert + chain + key
chmod 600 *.key *.pem; chmod 644 ca.crt odoo.pca.lab.crt
openssl verify -CAfile ca.crt odoo.pca.lab.crt
openssl x509 -in odoo.pca.lab.crt -noout -subject -ext subjectAltName -enddate
```

**Deploy.** `lb01/deploy.sh` renders `haproxy.cfg.tpl` with the secrets, refuses any leftover `@@` placeholder, copies the
PEM and the tmpfiles rule, sets SELinux context and boolean, validates with `haproxy -c` **on a `.new` file**, and only then
replaces the live file and reloads.

**Problems (in order).**

1. `unrendered placeholder` — the guard matched `@@...@@` in a *comment* of the template. Fix: comment reworded.
2. `ValueError: File spec /run/haproxy(/.*)? conflicts with equivalency rule '/run /var/run'; Try adding '/var/run/haproxy(/.*)?' instead`.
   Fix: fcontext declared on `/var/run/haproxy(/.*)?`. (A later `BrokenPipeError` from `semanage … | grep -q` made the
   idempotence check fail once — "already defined, modifying instead"; fixed by `grep -c` on `semanage fcontext -l -C`.)
3. `[ALERT] … failed to parse log-format : sample fetch <req.cook(SRV)…> may not be reliably used here because it needs 'HTTP request headers'`.
   Fix: `http-request capture req.cook(SRV) len 8` and `capture sc_http_req_rate(0) len 6`, logged with `%hr`.
4. All servers DOWN: `Layer7 wrong status, code: 500`. Odoo log: `KeyError: 'HTTP_HOST'` on `"GET /web/health HTTP/1.0"`.
   Cause: `option httpchk GET /web/health` sends HTTP/1.0 without Host. Fix:
   `http-check send meth GET uri /web/health ver HTTP/1.1 hdr Host odoo.pca.lab` → all 6 servers `UP L7OK`.
5. No `socat` for the runtime API → installed from the DVD.

**Browser trust.** Firefox: `ImportEnterpriseRoots` + `Certificates.Install` merged into
`/usr/lib/firefox-esr/distribution/policies.json` (original saved to `/root/pca-backup/firefox-policies.json.orig` on kali).
Chromium: `certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "PCA Lab Root CA" -i pki/ca.crt` — `libnss3-tools` first failed
with `404 Not Found` from http.kali.org, then installed after `apt-get update`.
Headless check: `chromium --headless=new --screenshot=evidence/phase4/browser-login.png https://odoo.pca.lab/web/login` →
French login page, no certificate warning.

**Public signup.** The login page offered "Vous n'avez pas de compte ?". `init_db.sh` now sets
`auth_signup.invitation_scope = b2b` → link gone, `/web/signup` 404.

**Verification (actual output, `evidence/phase4/checks.txt`, `selinux.txt`, `haproxy-log-sample.txt`).**

**`evidence/phase4/checks.txt`**

```text
### 2026-11-07T21:20:07+01:00
### 1. health through the LB with the system trust store (no -k)
{"status": "pass"}  -> HTTP 200, TLS verify result=0, 2
### 2. certificate presented
subject=C=TN, O=PCA Lab, CN=odoo.pca.lab issuer=C=TN, O=PCA Lab, CN=PCA Lab Root CA X509v3 Subject Alternative Name:      DNS:odoo.pca.lab, DNS:lb01.pca.lab, IP Address:192.168.100.20 
    TLS 1.1 refused: yes
### 3. HTTP -> HTTPS redirect
  http://odoo.pca.lab/ -> 301 Location: https://odoo.pca.lab/
### 4. security headers on /web/login
  strict-transport-security: max-age=31536000; includeSubDomains
  x-content-type-options: nosniff
  x-frame-options: SAMEORIGIN
  referrer-policy: strict-origin-when-cross-origin
  set-cookie: SRV=odoo2; path=/; HttpOnly; Secure
### 5. round robin: 30 requests without cookie -> server cookie assigned
       10 SRV=odoo1
       10 SRV=odoo2
       10 SRV=odoo3
### 6. persistence: same cookie -> same server (10 requests with SRV=odoo2)
200 200 200 200 200 200 200 200 200 200 
### 7. form login through the public URL (as a browser does: GET /web/login, csrf, POST)
  POST /web/login -> 303 redirect=https://odoo.pca.lab/web
  session_info: uid=8 login=vendeur1 db=pca_demo
  GET /web#action=sale.action_orders (web client) -> 200
  server cookie for this browser session: odoo3
### 8. websocket upgrade on /websocket (be_odoo_ws, gevent port)
  -> HTTP 101
### 9. database manager blocked at the edge
  /web/database/manager -> 403
### 10. stats page (kali only, auth)
  no auth  -> 401
  with auth -> 200
### 11. boundaries
  app01 -> lb01:8404 (not kali): to connect to 192.168.100.20 port 8404: No route to host
000
  app01 -> lb01:443 (lab subnet allowed): 200
  kali NAT -> lb01 NAT IP 443: to 192.168.13.138 port 443 after 0 ms: Could not connect to server
000
### 12. HAProxy server state (runtime API)
  be_odoo     odoo1    12  UP  L7OK
  be_odoo     odoo2    21  UP  L7OK
  be_odoo     odoo3    14  UP  L7OK
  be_odoo     BACKEND  47  UP  
  be_odoo_ws  odoo1    1   UP  L7OK
  be_odoo_ws  odoo2    0   UP  L7OK
  be_odoo_ws  odoo3    0   UP  L7OK
  be_odoo_ws  BACKEND  1   UP  
  stats       BACKEND  0   UP
```

**`evidence/phase4/selinux.txt`**

```text
haproxy_connect_any --> on
            system_u:object_r:etc_t:s0 /etc/haproxy/certs/odoo.pca.lab.pem
system_u:object_r:haproxy_var_run_t:s0 /run/haproxy/admin.sock
total 4
-rw-r-----. 1 root haproxy 1719 Nov  7 21:19 odoo.pca.lab.pem
haproxy AVC denials today: 0
system_u:system_r:haproxy_t:s0    36478 ?        00:00:00 haproxy
system_u:system_r:haproxy_t:s0    36677 ?        00:00:01 haproxy
```

### Phase 5 — Demo scenarios (2026-11-07 21:25 → 2026-11-08 01:29, commits `c1beca0`, `5cf55d9`, `544ee72`)

**Goal.** k6 + scenario scripts S1–S5 + `reset_lab.sh`, each scenario at least twice, numbers in `results/raw/`.

**k6 install** (kali, not in Kali apt):
```bash
V=$(curl -sS -o /dev/null -w '%{redirect_url}' https://github.com/grafana/k6/releases/latest | sed 's|.*/tag/||')   # v2.3.0
curl -sSL -o k6.tgz ".../k6-$V-linux-amd64.tar.gz"; curl -sSL -o sums.txt ".../k6-$V-checksums.txt"
grep linux-amd64.tar.gz sums.txt | awk '{print $1"  k6.tgz"}' | sha256sum -c -      # k6.tgz: OK
tar xzf k6.tgz && sudo install -m 755 k6-$V-linux-amd64/k6 /usr/local/bin/k6       # k6 v2.3.0 (commit/e088784614, go1.26.8)
```

**Trusted-only server header.** HAProxy sets `X-PCA-Server: <server>` in responses only for requests carrying the secret
load-test header (tested: with header `odoo1`; without header / wrong value: absent).

**Tooling.** `scenarios/lib.sh` (shared helpers), `probe.py` (user probe), `probe_summary.py`, `k6/odoo_load.js`,
`reset_lab.sh`, `s1…s5`, `run_all.sh`, later `demo_watch.sh` and `k6/browser_session.js` — full contents in section 4.

**Problems and fixes (chronological).**

1. `scenarios/lib.sh:4: BASH_SOURCE[0]: parameter not set` — the interactive shell is zsh. Fix: scripts run with bash
   (shebang), interactive tests through `bash -c`.
2. A debugging command containing `rm $J` (variable path) was blocked by a safety check. Fix: fixed file paths, no `rm`
   of variable paths (S4 truncates its cookie jar instead).
3. **k6 "Odoo Session Expired"** — smoke test: 195 requests, 0 HTTP failures but `rpc_errors=108`. Logging the bodies showed
   `SessionExpiredException` from iteration 1 on; HAProxy log showed `{|}` (no SRV cookie) on the first request of each
   iteration. Cause: k6 resets each VU's cookie jar at the end of every iteration. Fix: `noCookiesReset: true` →
   `k6: reqs=1070 rps=34.2 p95=62.2ms failed=0 (0.000%) rpc_errors=0`.
4. **S1 first run** (21:34): PASS, but probe 1 failure (0.211 %) = HTTP 502, termination `SHVN`, plus a 1979 ms request.
   Log line: `be_odoo/odoo1 0/0/1/-1/552 502 209 SHVN … "POST /web/dataset/call_kw/sale.order/search_count"`.
   Fixes in steps: `option redispatch 1` (redispatch on every retry; the 2 s request was retries with ~1 s turn-around on the
   dead server) and `retry-on conn-failure empty-response`. Still 1 failure; stats showed `eresp=4 redispatch=3` on odoo1 —
   k6 requests were replayed, the probe's was not. Added `option http-buffer-request`. Still 1 failure (stop) / **0 (kill)**.
   The probe was then made browser-like (persistent HTTP/1.1 connection instead of urllib `Connection: close`): still exactly
   1 failure with a graceful stop, this time `RemoteDisconnected` with no matching 5xx line in the HAProxy log, while two other
   requests in the same second were redispatched (`--DI`, `+1`). Accepted and documented (≤ 1 % criterion; drain → 0).
5. **S3 counters**: `clear counters` resets only maxima; per-server split was cumulative. Fix: `clear counters all`.
6. **S3 result**: 1 node 106.3 req/s → 3 nodes 90.0 req/s with app01 CPU 93–94 %. Added `CPU_PER_NODE` variant
   (`docker update --cpus 0.66`, reverted by a `trap`) and kali CPU sampling.
7. **Host suspended** ~21:52 → 00:37 during an S3 run: `rps=0.8` with 8 068 requests, Odoo log
   `WorkerHTTP (15) timeout after 240s` / `WorkerCron (19) timeout after 240s` at 23:35:44 UTC. Containers showed
   "Up 3 hours" while `uptime` showed 1 h 08 (suspend not counted). Runs marked INVALID in `results.tsv`, re-run.
   After the resume the host was slower (same smoke profile p95 62 ms → 115 ms).
8. **S3 capped, 1 node**: 93–95 % failures — `Server be_odoo/odoo1 is DOWN, reason: Layer7 timeout … 0 active and 0 backup
   servers left` → 503s. Kept as a finding; metric changed to **successful** req/s (`ok_rps`).
9. **S4 never triggered** at 200 req/10 s: `600 × 200`, stick-table `http_req_rate(10000)=17`, peaks ~107 per 10 s (one client
   cannot get more than ~11 login pages/s from this backend). Measured a real browser session with the k6 browser module:
   the first script used `/odoo/action-sale.action_orders` (Odoo 18 URL → 404 page), fixed to
   `/web#action=sale.action_orders` → **33 requests** through HAProxy for login + cold web client + Sales list
   (screenshot `evidence/phase4/browser-sales-orders.png`). Limit set to **100 / 10 s**. Script bug: `FIRST429=$(grep … | head)`
   aborted under `pipefail` when there was no 429 — fixed with `|| true`.
10. **S4 wrong-header subtest**: 50 requests were under the limit, so "still throttled" was not proven. Changed to 150 and added
    to the PASS condition (second run: `150 × 429`).
11. **S1[stop] "FAIL" in the second campaign** (detection 10 220 ms > 9 000 ms): the metric started at the `docker stop`
    command and included Odoo's graceful shutdown (node still serving). Fix: detection measured from
    `docker inspect -f '{{.State.FinishedAt}}' odoo-1` to the DOWN state (NTP-synced clocks).
12. **Cold node flapping** (S1[kill], 00:59): probe logged in on odoo1 but its first call went to odoo3 (`--DI`);
    `/web/session/authenticate` took 12.7–14.7 s and `Server be_odoo/odoo1 is DOWN, reason: Layer7 timeout`.
    Fix: `slowstart 15s` on `be_odoo` servers and `warm_node` (direct requests from lb01 to the node) in `reset_lab.sh` and in
    S2 before `state ready`.

**Campaign** (`scenarios/run_all.sh`, 2026-11-08 00:57–01:13) then targeted re-runs of S1 (01:23–01:28). Verdict lines
(actual output, `/tmp` task output and `results/raw/results.tsv`):

```
VERDICT S1[stop] FAIL: detection 10220 ms (HAProxy log 9820 ms), user probe failed 0.211% max gap 2836 ms, k6 failed 0 (0%), session lost 0x, path odoo1->odoo3, back in LB 17405 ms after restart
VERDICT S1[kill] PASS: detection 7507 ms (HAProxy log 7649 ms), user probe failed 0.0% max gap 1260 ms, k6 failed 0 (0%), session lost 0x, path odoo3, back in LB 16390 ms after restart
VERDICT S2 PASS: 3 nodes replaced one by one in 155 s; k6 4017 requests, 0 failed, 0 RPC errors; user probe 0/833 failed, max gap 1382 ms, path odoo3->odoo1
VERDICT S3[shared] DONE: 1 node 52.9 successful req/s (raw 52.9, error rate 0) p95 283.0 ms (app01 CPU 91.6%) -> 3 nodes 43.6 successful req/s (error rate 0) p95 395.5 ms (CPU 94.1%): successful throughput x0.82, p95 x1.4 (app01 has 2 vCPU)
VERDICT S3[capped0.66cpu] DONE: 1 node 15.7 successful req/s (raw 224.8, error rate 0.93014) p95 362.5 ms (app01 CPU 36.3%) -> 3 nodes 27.3 successful req/s (error rate 0) p95 598.5 ms (CPU 91.7%): successful throughput x1.74, p95 x1.65 (app01 has 2 vCPU)
VERDICT S4 PASS: 600-request burst -> 175 x 200, 425 x 429 (first at #175, limit 100/10s), backend saw only 175; exempt client:     300 200 ; normal login afterwards 200/303/200
VERDICT S5 PASS: hung node detected DOWN in 10329 ms, back UP 3764 ms after unpause; state sequence: UP,* L7OK UP 2/3,L7TOUT UP 2/3,* L7TOUT UP 1/3,L7TOUT UP 1/3,* L7TOUT DOWN,L7TOUT DOWN 1/2,L7OK UP,L7OK ; 4 log transitions; stats CSV/HTML + Prometheus captured
RESET OK: 4 containers healthy, 6/6 HAProxy servers UP, stick-table cleared (01:13:15)
VERDICT S1[stop] PASS: node stopped serving at +3416 ms, LB detection 2795 ms after that (6199 ms after the command, HAProxy log 6805 ms), user probe failed 0.212% max gap 1351 ms, k6 failed 0 (0%), session lost 0x, path odoo1->odoo3, back in LB 8092 ms after restart
VERDICT S1[stop] PASS: node stopped serving at +3316 ms, LB detection 2860 ms after that (6168 ms after the command, HAProxy log 6400 ms), user probe failed 0.211% max gap 1395 ms, k6 failed 0 (0%), session lost 0x, path odoo1->odoo3, back in LB 8243 ms after restart
VERDICT S1[kill] PASS: node stopped serving at +1655 ms, LB detection 4492 ms after that (6137 ms after the command, HAProxy log 6731 ms), user probe failed 0.0% max gap 1249 ms, k6 failed 0 (0%), session lost 0x, path odoo1->odoo3, back in LB 7935 ms after restart
```

### Phase 6 — Stretch (01:29–01:37, commit `d7ead95`)

**RAM check first** (rule: keep ≥ 600 MB free on app01): app01 2 670 MB available, kali 1 741 MB available.

**6.1 PostgreSQL streaming replica.** Service `db-replica` added to the compose file (`pca-db-replica`, `postgres:16`,
384 MiB, volume `pg-replica`, custom entrypoint). `deploy.sh` renders `setup-replication.sql` from the template with
`REPL_PASSWORD`, installs it mode 600 root-only, and after the primary is ready runs it **through psql stdin**, appends
`host replication replicator samenet scram-sha-256` to `pg_hba.conf` if absent, and reloads the config — before the
other services start.

```bash
[kali] ./app01/deploy.sh
[app01] docker logs pca-db-replica   # "completed backup recovery …", "ready to accept read-only connections",
                                     # "started streaming WAL from primary at 0/8000000 on timeline 1"
[app01] docker exec pca-db psql -U odoo -d postgres -tAc "select application_name, state, sync_state, replay_lag from pg_stat_replication"
# -> walreceiver|streaming|async|
[kali] ./scenarios/s6_db_failover.sh     # twice
```

S6 output (actual):
```
[01:30:28.597] replay lag over 10 s: max 3.69 ms, avg 0.92 ms, max 0 bytes behind
[01:30:31.000] last acknowledged write id=208, last row on replica id=208 -> lost 0 committed rows (RPO = 0 ms of writes)
[01:30:35.465] replica promoted in 2813 ms, writable=yes, now answers as 'db' (5954 ms after the crash)
[01:30:35.473] Odoo answering again through the LB 6869 ms after the crash
[01:31:33.213] after restore: replica streaming
VERDICT S6 PASS: replication lag max 3.69 ms (avg 0.92); primary crash -> lost 0 committed rows (RPO 0 ms); promotion 2813 ms; Odoo back 6869 ms after crash (manual); probe failed 27/195; replica after restore: streaming
VERDICT S6 PASS: replication lag max 5.65 ms (avg 1.33); primary crash -> lost 0 committed rows (RPO 0 ms); promotion 1542 ms; Odoo back 5387 ms after crash (manual); probe failed 21/185; replica after restore: streaming
```
After both runs `select count(*) from sale_order` on the primary = 20 (Odoo data intact).

**6.2 Prometheus + Grafana on kali.** Images pulled (`prom/prometheus:v2.55.1` 291 MB, `grafana/grafana-oss:11.3.0` 493 MB),
`./monitoring/up.sh`. Target `haproxy-lb01 up`; `haproxy_server_status{proxy="be_odoo",state="UP"}` = 1 for the 3 servers;
memory 131 MB + 68 MB. Problem: the first dashboard generator crashed with `TypeError: not enough arguments for format string`
(`state%("be_odoo",)*3` — `%` binds before `*`); fixed with a function. Evidence: a drain → maint → ready of odoo2 and a
kill/start of odoo3 under k6 load, then `chromium --headless=new … --screenshot=evidence/phase6/grafana-dashboard.png
"http://127.0.0.1:3000/d/pca-haproxy/?orgId=1&from=now-3m&to=now&kiosk"` — the state timeline shows DRAIN (blue),
MAINT (orange), DOWN (red), the redispatch panel shows odoo3 redispatches, 0 × 5xx at the edge.

**`evidence/phase6/replica-status.txt`**

```text
 application_name | client_addr |   state   | sync_state |    write_lag    |   replay_lag    
------------------+-------------+-----------+------------+-----------------+-----------------
 walreceiver      | 172.18.0.6  | streaming | async      | 00:00:00.000225 | 00:00:00.002995
(1 row)

NAME             MEM USAGE / LIMIT
pca-db-replica   23.26MiB / 384MiB
odoo-3           379.8MiB / 800MiB
odoo-2           371.9MiB / 800MiB
odoo-1           370.4MiB / 800MiB
pca-db           89.57MiB / 512MiB
               total        used        free      shared  buff/cache   available
Mem:            4902        2320        1143         131        1931        2581
Swap:           5119           0        5119
```

### After phase 6 — dry run, presentation, deck (01:46–02:05, commits `cabfcd9`, `1f3be20`, `4f08c89`)

- **Dry run** of `DEMO-CHECKLIST.md` (results in `evidence/dry-run/README.md`): prep 38 s, edge 56 s, node failure 61 s
  (live view 300 lines, 0 errors), rolling update 151 s (0 failed), observability + recovery 42 s (HAProxy restart: service
  back in 513 ms; restart of all 3 Odoo nodes: first 200 after 14 085 ms). Fixes: `ssh -q` everywhere (post-quantum warning),
  log filter on the status field (the old grep matched a byte count of 429 on a websocket line), full `check_phase4.sh`,
  `curl -sS -m3`.
- **`PRESENTATION-27-11.md`**: 5-minute outline (7 talking slides, timings, script, French).
- **Slide deck** (8 slides) published as a private claude.ai artifact; source copied to `presentation/deck/`.

**`evidence/dry-run/README.md`**

```text
# Demo dry run — 2026-11-08 01:46–01:54

Executed DEMO-CHECKLIST.md end to end from kali (no browser clicks; the browser parts were replaced by the probe view).

| Section | Duration | Result | File |
|---------|----------|--------|------|
| Preparation (ssh, reset, check_phase4, log follow, Grafana) | 38 s | OK | 00-prep.txt |
| 1. Edge security + S4 | 56 s | OK: 301, headers, 403, direct access refused, 100 x 200 / 500 x 429, login OK after | 01-edge.txt |
| 2. Node failure (kill odoo-2 / start) | 61 s | OK: 300 probe lines, 0 errors, node switch < 200 ms, DOWN ~7 s after kill, UP 7 s after start | 02-*.txt |
| 3. Rolling update S2 | 151 s | OK: 0 failed (k6 3772, probe 627, live view 748 lines) | 03-*.txt |
| 5. Observability + recovery commands | 42 s | OK: stats/Grafana 200; clear table; haproxy restart 0.5 s; restart of all Odoo nodes = 14 s outage (last resort) | 05-*.txt |

Issues found and fixed in the checklist:
1. `ssh` prints 3 "post-quantum" warning lines each call -> use `ssh -q` everywhere.
2. Zone C log filter matched " 429 " in the byte-count column (websocket line) and printed every transition twice -> awk filter on the status field, `[WARNING]` copies removed (tested: zoneC-filter-test.txt).
3. `check_phase4.sh | head -30` hid the stats/boundary checks -> run it in full.
4. `curl -m3` showed a progress meter -> `curl -sS -m3`.
5. Round-robin split varies (10/10/10, 11/8/11) -> wording adjusted in DEFENSE-NOTES.
```

---

## 4. Final configuration reference

### 4.1 app01 — `/opt/pca-odoo/docker-compose.yml` (read back from app01; identical to `app01/docker-compose.yml` except comments, checked with `diff`)

**`docker-compose.yml (deployed copy)`**

```yaml
# PCA lab - Odoo 17 x3 + PostgreSQL 16 on app01. Source of truth: ~/pca-lab/app01/
# Deployed to /opt/pca-odoo by ~/pca-lab/app01/deploy.sh
name: pca-odoo

x-odoo: &odoo
  image: odoo:17
  restart: unless-stopped
  depends_on:
    db:
      condition: service_healthy
  # Odoo reads db_host/db_password etc. from odoo.conf (rendered from .secrets, mode 600)
  command: ["odoo", "-c", "/etc/odoo/odoo.conf"]
  volumes:
    - odoo-data:/var/lib/odoo                      # ONE shared filestore + sessions for all nodes
    - ./config/odoo.conf:/etc/odoo/odoo.conf:ro,z    # :z = shared label (3 containers read it); :Z would be private to one
  mem_limit: 800m
  memswap_limit: 1g
  cpus: 2
  stop_grace_period: 20s
  healthcheck:
    test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8069/web/health || exit 1"]
    interval: 10s
    timeout: 5s
    retries: 3
    start_period: 40s
  networks: [backend]
  logging:
    driver: journald
    options: { tag: "{{.Name}}" }

services:
  db:
    image: postgres:16
    container_name: pca-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?missing}
      POSTGRES_DB: postgres
    volumes:
      - pg-data:/var/lib/postgresql/data
    # NO "ports:" -> PostgreSQL is only reachable inside the Docker network
    command: ["postgres", "-c", "max_connections=200", "-c", "shared_buffers=128MB", "-c", "wal_level=replica", "-c", "max_wal_senders=5", "-c", "wal_keep_size=256MB"]
    mem_limit: 512m
    shm_size: 128m
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo -d postgres"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks: [backend]
    logging:
      driver: journald
      options: { tag: "{{.Name}}" }

  # Phase 6: asynchronous streaming replica (hot standby), promoted manually in scenario s6 (RPO/RTO of the DB tier)
  db-replica:
    image: postgres:16
    container_name: pca-db-replica
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGPASSWORD: ${REPL_PASSWORD:?missing}
      PGDATA: /var/lib/postgresql/data/pgdata
    entrypoint: ["/bin/bash", "/pca/replica-entrypoint.sh"]
    volumes:
      - pg-replica:/var/lib/postgresql/data
      - ./scripts/replica-entrypoint.sh:/pca/replica-entrypoint.sh:ro,z
    mem_limit: 384m
    shm_size: 64m
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo -d postgres"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks: [backend]
    logging:
      driver: journald
      options: { tag: "{{.Name}}" }

  odoo-1:
    <<: *odoo
    container_name: odoo-1
    hostname: odoo-1
    ports: ["192.168.100.10:8069:8069", "192.168.100.10:8072:8072"]
  odoo-2:
    <<: *odoo
    container_name: odoo-2
    hostname: odoo-2
    ports: ["192.168.100.10:8169:8069", "192.168.100.10:8172:8072"]
  odoo-3:
    <<: *odoo
    container_name: odoo-3
    hostname: odoo-3
    ports: ["192.168.100.10:8269:8069", "192.168.100.10:8272:8072"]

volumes:
  pg-data:
  odoo-data:
  pg-replica:

networks:
  backend:
    driver: bridge
```

Design choices:
- **YAML anchor `x-odoo`**: the three nodes are strictly identical (image, config, volume, limits, healthcheck); only name and
  ports differ. Rejected: three hand-copied service blocks (drift risk).
- **One named volume `odoo-data` for `/var/lib/odoo`** (filestore and `sessions/`) shared by the three nodes → any node can
  serve any session (proved in phase 3 and S1). Rejected: per-node volumes + mandatory stickiness (a node loss = lost sessions).
- **`db` has no `ports:`** → PostgreSQL only on the Docker network. Rejected: publishing 5432 for admin convenience.
- **Ports bound to `192.168.100.10`** → nothing on the NAT network (192.168.13.0/24) even if filtering failed.
- **Memory**: db 512 MiB, each Odoo 800 MiB (≈ 2.9 GiB, the "about 3 GB" budget), replica 384 MiB.
- **Healthchecks**: `pg_isready` for databases; `curl /web/health` inside each Odoo container. `depends_on: service_healthy`.
- **`:z` (not `:Z`) on `odoo.conf`**: shared SELinux label, see phase 3 problem 6.
- **journald logging driver** with the container name as tag → `journalctl CONTAINER_NAME=odoo-1`.
- **`wal_level=replica`, `max_wal_senders=5`, `wal_keep_size=256MB`** on the primary from day one, so the replica could be
  added later without restarting it with new parameters.
- **Replica entrypoint** with `pg_basebackup -X stream -S replica1 -R` (slot + `standby.signal`), `hot_standby=on`,
  `hot_standby_feedback=on`; `max_connections=200` (must be ≥ the primary's).

### 4.2 app01 — `/opt/pca-odoo/config/odoo.conf` (read back from app01, secrets redacted)

**`odoo.conf (deployed copy)`**

```ini
; PCA lab Odoo config. Template in git; rendered with secrets by deploy.sh (never commit the rendered file)
[options]
addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons
data_dir = /var/lib/odoo
db_host = db
db_port = 5432
db_user = odoo
db_password = <see .secrets>
db_name = pca_demo
dbfilter = ^pca_demo$
list_db = False
admin_passwd = <see .secrets>
proxy_mode = True
http_port = 8069
gevent_port = 8072
workers = 2
max_cron_threads = 1
db_maxconn = 32
limit_memory_soft = 335544320
limit_memory_hard = 503316480
limit_time_cpu = 120
limit_time_real = 240
limit_request = 8192
log_level = info
```

Template in git: `app01/config/odoo.conf.tpl` (placeholders `@@POSTGRES_PASSWORD@@`, `@@ODOO_ADMIN_PASSWD@@`). Installed
`root:101` mode 640 (gid 101 = `odoo` in the image; on the host gid 101 is named `ssh_keys`, which is why `ls -l` shows that group).

| Directive | Why |
|-----------|-----|
| `proxy_mode = True` | trust `X-Forwarded-For/Proto/Host` from HAProxy: real client IP in logs, `https://` URLs. Safe only because nodes are reachable from lb01 only |
| `workers = 2`, `max_cron_threads = 1` | prefork mode (required for the separate gevent/websocket process); 2 workers per node × 3 nodes on 2 vCPU |
| `gevent_port = 8072` | websocket/bus endpoint, routed by HAProxy `be_odoo_ws` |
| `list_db = False`, `dbfilter = ^pca_demo$`, `db_name = pca_demo` | no database manager, single allowed DB (also blocked at the edge) |
| `admin_passwd` | random master password (`<see .secrets>`) |
| `limit_memory_soft/hard = 320/480 MiB` | a worker is recycled before the 800 MiB container limit |
| `limit_time_real = 240` | HAProxy `timeout server 250s` is set just above |
| `db_maxconn = 32` | bounded pool per node |

### 4.3 app01 — Docker daemon and DOCKER-USER

`/etc/docker/daemon.json` (from `app01/daemon.json`):

**`app01/daemon.json`**

```json
{
  "selinux-enabled": true,
  "log-driver": "journald",
  "live-restore": false,
  "no-new-privileges": true
}
```

**`app01/scripts/pca-docker-user.sh`**

```bash
#!/bin/bash
# Default-deny for traffic entering Docker containers from the physical NICs (Docker DNAT bypasses firewalld zones).
# Only lb01 may open connections to the Odoo containers (container ports 8069 http, 8072 websocket).
# Idempotent: DOCKER-USER is owned by us (Docker never writes to it), so we flush and rebuild it.
set -euo pipefail
LB=192.168.100.20
for i in $(seq 1 30); do iptables -nL DOCKER-USER >/dev/null 2>&1 && break; sleep 1; done
iptables -F DOCKER-USER
iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -A DOCKER-USER -i ens160 -s $LB -p tcp -m multiport --dports 8069,8072 -m comment --comment "pca: lb01 -> odoo" -j RETURN
iptables -A DOCKER-USER -i ens+ -m conntrack --ctstate NEW -m comment --comment "pca: default deny to containers" -j REJECT --reject-with tcp-reset -p tcp
iptables -A DOCKER-USER -i ens+ -m conntrack --ctstate NEW -m comment --comment "pca: default deny to containers" -j REJECT
iptables -A DOCKER-USER -j RETURN
echo "DOCKER-USER rules applied"
```

**`app01/scripts/pca-docker-user.service`**

```ini
[Unit]
Description=PCA lab: restrict access to published Docker ports (DOCKER-USER chain)
After=docker.service firewalld.service
PartOf=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/pca-odoo/scripts/pca-docker-user.sh

[Install]
WantedBy=docker.service
```

Live chain on app01:
```
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -s 192.168.100.20/32 -i ens160 -p tcp -m multiport --dports 8069,8072 -m comment --comment "pca: lb01 -> odoo" -j RETURN
-A DOCKER-USER -i ens+ -p tcp -m conntrack --ctstate NEW -m comment --comment "pca: default deny to containers" -j REJECT --reject-with tcp-reset
-A DOCKER-USER -i ens+ -m conntrack --ctstate NEW -m comment --comment "pca: default deny to containers" -j REJECT --reject-with icmp-port-unreachable
-A DOCKER-USER -j RETURN
```
Matching on the **container** ports 8069/8072 works because DNAT happens before FORWARD. `-i ens+` limits the policy to
traffic arriving from physical NICs (container-to-container and outbound traffic untouched). Rejected alternatives: firewalld
`--direct` rules (deprecated, ordering issues with Docker), disabling Docker's iptables (breaks networking).

### 4.4 app01 — replication

**`app01/scripts/replica-entrypoint.sh`**

```bash
#!/bin/bash
# PostgreSQL streaming replica bootstrap (phase 6). First start: pg_basebackup from the primary "db" using slot replica1,
# -R writes standby.signal + primary_conninfo. Next starts: just run postgres in hot standby.
set -euo pipefail
mkdir -p "$PGDATA"; chown -R postgres:postgres "$(dirname "$PGDATA")"; chmod 700 "$PGDATA"
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_isready -h db -U replicator -q; do echo "waiting for primary"; sleep 1; done
  echo "initial base backup from primary (slot replica1)"
  gosu postgres pg_basebackup -h db -U replicator -D "$PGDATA" -X stream -S replica1 -R -c fast
fi
exec gosu postgres postgres -c hot_standby=on -c max_connections=200 -c shared_buffers=64MB \
  -c wal_level=replica -c max_wal_senders=5 -c hot_standby_feedback=on
```

**`app01/scripts/setup-replication.sql.tpl`**

```text
-- Idempotent primary-side setup for the streaming replica (rendered with REPL_PASSWORD, sent over stdin, never on a command line)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH REPLICATION LOGIN;
  END IF;
END $$;
ALTER ROLE replicator WITH PASSWORD '@@REPL_PASSWORD@@';
SELECT pg_create_physical_replication_slot('replica1') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica1');
```

Live state: `pg_hba.conf` ends with `host all all all scram-sha-256` / `host replication replicator samenet scram-sha-256`;
slot `replica1` active; `walreceiver|streaming|async`.

### 4.5 app01 — deployment scripts

**`app01/deploy.sh`**

```bash
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
```

**`app01/init_db.sh`**

```bash
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
ICP.set_param('auth_signup.invitation_scope', 'b2b')   # no public self-registration on an ERP
print('COUNTS sale.order=%d res.partner=%d product=%d demo=%s' % (env['sale.order'].search_count([]), env['res.partner'].search_count([]), env['product.product'].search_count([]), env.ref('base.module_base').demo))
env.cr.commit()
PY
ssh -q $H "cd /opt/pca-odoo && sudo docker compose up -d 2>&1 | tail -1"
echo "init done"
```

### 4.6 lb01 — `/etc/haproxy/haproxy.cfg` (read back from lb01, secrets redacted)

**`haproxy.cfg (deployed copy)`**

```haproxy
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
    acl loadtest   req.hdr(<see .secrets>) -m str <see .secrets>
    acl too_fast   sc_http_req_rate(0) gt 100
    http-request track-sc0 src unless loadtest
    http-request capture req.cook(SRV) len 8
    http-request capture sc_http_req_rate(0) len 6
    http-request deny deny_status 429 if !loadtest too_fast
    http-request set-var(txn.trusted) bool(true) if loadtest
    http-request del-header <see .secrets>          # never forwarded to Odoo
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
    # slowstart: a node coming back UP ramps its weight over 15 s (cold Odoo workers are slow at first)
    default-server inter 2s fall 3 rise 2 maxconn 32 slowstart 15s check
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
    stats auth <see .secrets>:<see .secrets>
    # Prometheus metrics (scraped from kali, port 8404 is firewalled to kali only)
    http-request use-service prometheus-exporter if { path /metrics }
```

Section by section:

- **global**: `log stdout` (RHEL's unit runs `haproxy -Ws` in the foreground, so stdout goes to journald and works despite
  `chroot`; rejected: rsyslog UDP, more moving parts). `chroot` + `user haproxy`. Admin socket `/run/haproxy/admin.sock`
  mode 600 level admin (runtime API: drain/maint/ready, show stat, clear table). TLS ≥ 1.2, ECDHE + AEAD ciphers only,
  `no-tls-tickets`.
- **defaults**: `option redispatch` + `retries 3`; `timeout http-request 10s` (slowloris); `timeout server 250s` (> Odoo
  `limit_time_real`); `timeout check 2s` (a frozen node fails a check after 2 s).
- **fe_http**: bind on the lab IP only, permanent redirect to HTTPS.
- **fe_https**: `alpn h2,http/1.1`; `option forwardfor`; unique request ID added as `X-Request-ID`; custom log format
  (timers `%TR/%Tw/%Tc/%Tr/%Ta`, termination state `%tsc`, captures `%hr` = `{SRV cookie|current rate}`).
  Rate limit: stick-table per source IP, `http_req_rate(10s)`; requests carrying the exact secret header are not tracked;
  others above **100 per 10 s** get **429** from HAProxy; the secret header is removed before forwarding. `/web/database*`
  denied with 403. `X-Forwarded-Proto https`, `X-Forwarded-Host`. HSTS 1 year, nosniff, `SAMEORIGIN`, Referrer-Policy,
  `Server`/`X-Powered-By` removed. `X-PCA-Server` only for trusted test clients. `/websocket` → `be_odoo_ws`.
- **be_odoo**: `balance roundrobin` (short homogeneous requests; rejected `leastconn` here, used for websockets);
  HTTP/1.1 health check with Host header; `cookie SRV insert indirect nocache httponly secure` (stickiness for warm caches
  and drain, not for correctness — sessions are shared); `option redispatch 1` + `retry-on conn-failure empty-response` +
  `option http-buffer-request` (zero-error failover on crash; risk: replay of a POST whose reply was lost — Odoo commits at
  the very end of a request); `inter 2s fall 3 rise 2` (detection ≈ 3 checks); `maxconn 32` per server (queue in HAProxy,
  not in Odoo); `slowstart 15s` (cold workers).
- **be_odoo_ws**: `leastconn` (connections up to 1 h), `timeout tunnel 1h`, same health check.
- **listen stats**: lab IP only (firewalled to kali), basic auth, refresh 2 s, legends; `/metrics` served by the built-in
  Prometheus exporter (`USE_PROMEX`).

Template in git: `lb01/haproxy.cfg.tpl`; deploy script:

**`lb01/deploy.sh`**

```bash
#!/bin/bash
# Deploy HAProxy config + TLS bundle to lb01. Idempotent. Validates with `haproxy -c` before reload.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./.secrets
RATE_LIMIT=${RATE_LIMIT:-100}     # requests per 10 s per source IP; a full cold browser login = 33 requests (see DECISIONS.md)
H=lb01
./pki/make_pki.sh >/dev/null
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT; chmod 700 "$STAGE"
sed -e "s|@@LOADTEST_HEADER_NAME@@|$LOADTEST_HEADER_NAME|g" -e "s|@@LOADTEST_HEADER_VALUE@@|$LOADTEST_HEADER_VALUE|g" \
    -e "s|@@HAPROXY_STATS_USER@@|$HAPROXY_STATS_USER|g" -e "s|@@HAPROXY_STATS_PASSWORD@@|$HAPROXY_STATS_PASSWORD|g" \
    -e "s|@@RATE_LIMIT@@|$RATE_LIMIT|g" lb01/haproxy.cfg.tpl > "$STAGE/haproxy.cfg"
grep -q '@@' "$STAGE/haproxy.cfg" && { echo "unrendered placeholder"; exit 1; }
cp pki/odoo.pca.lab.pem lb01/pca-haproxy.tmpfiles.conf "$STAGE/"
ssh -q $H "rm -rf /tmp/pca-lb-stage; mkdir -m 700 /tmp/pca-lb-stage"
scp -q "$STAGE"/* $H:/tmp/pca-lb-stage/
ssh -q $H "sudo bash -s" <<'REMOTE'
set -euo pipefail
S=/tmp/pca-lb-stage
mkdir -p /root/pca-backup /etc/haproxy/certs
[ -f /root/pca-backup/haproxy.cfg.orig ] || cp -a /etc/haproxy/haproxy.cfg /root/pca-backup/haproxy.cfg.orig
cp -a /etc/haproxy/haproxy.cfg /root/pca-backup/haproxy.cfg.prev
# runtime dir for the admin socket (+ SELinux label)
install -m 644 $S/pca-haproxy.tmpfiles.conf /etc/tmpfiles.d/pca-haproxy.conf
[ "$(semanage fcontext -l -C | grep -c '^/var/run/haproxy(/')" -gt 0 ] || semanage fcontext -a -t haproxy_var_run_t '/var/run/haproxy(/.*)?'
systemd-tmpfiles --create /etc/tmpfiles.d/pca-haproxy.conf; restorecon -R /run/haproxy
# SELinux: allow haproxy_t to connect to the non-standard Odoo ports (8069/8072/8169/...)
[ "$(getsebool haproxy_connect_any | awk '{print $3}')" = on ] || setsebool -P haproxy_connect_any 1
install -m 640 -o root -g haproxy $S/odoo.pca.lab.pem /etc/haproxy/certs/odoo.pca.lab.pem
install -m 640 -o root -g haproxy $S/haproxy.cfg /etc/haproxy/haproxy.cfg.new
restorecon -R /etc/haproxy
if haproxy -c -q -f /etc/haproxy/haproxy.cfg.new -f /etc/haproxy/conf.d; then
  mv /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg; restorecon /etc/haproxy/haproxy.cfg
  systemctl enable -q haproxy
  if systemctl is-active -q haproxy; then systemctl reload haproxy; echo "haproxy reloaded"; else systemctl start haproxy; echo "haproxy started"; fi
else
  echo "CONFIG INVALID - kept previous config"; rm -f /etc/haproxy/haproxy.cfg.new; exit 1
fi
rm -rf $S
REMOTE
```

`/etc/tmpfiles.d/pca-haproxy.conf`: `d /run/haproxy 0750 root haproxy -`.

### 4.7 firewalld (read back)

**app01** — zone `public`, interfaces `ens160 ens224`, services: none, ports: none, rich rules:
```
rule family="ipv4" source address="192.168.100.30" service name="ssh" accept
rule family="ipv4" source address="192.168.100.20" port port="8069" protocol="tcp" accept   (+ 8072 8169 8172 8269 8272)
```
**lb01** — zone `public`, interfaces `ens160 ens192`, services: none, ports: none, rich rules:
```
rule family="ipv4" source address="192.168.100.0/24" service name="http" accept
rule family="ipv4" source address="192.168.100.0/24" service name="https" accept
rule family="ipv4" source address="192.168.100.30" port port="8404" protocol="tcp" accept
rule family="ipv4" source address="192.168.100.30" service name="ssh" accept
```
Zone target `default` = REJECT for everything else (an immediate "connection refused", easy to show). Rejected: zone `drop`
(silent timeouts, harder to diagnose live).

### 4.8 SELinux

| Machine | Setting | Value / reason |
|---------|---------|----------------|
| both | mode | Enforcing (runtime and `/etc/selinux/config`) |
| lb01 | boolean `haproxy_connect_any` | `on` — haproxy_t may connect to the non-standard Odoo ports |
| lb01 | fcontext (local) | `/var/run/haproxy(/.*)?` → `haproxy_var_run_t` (admin socket directory) |
| app01 | Docker | `selinux-enabled: true` → containers `container_t` with per-container MCS; `odoo.conf` `container_file_t:s0` via `:z` |

### 4.9 sshd (effective, `sshd -T`, read back)

lb01: `logingracetime 30`, `maxauthtries 3`, `clientaliveinterval 300`, `clientalivecountmax 2`, `permitrootlogin no`,
`pubkeyauthentication yes`, `passwordauthentication no`, `kbdinteractiveauthentication no`, `x11forwarding no`,
`permitemptypasswords no`, `allowtcpforwarding no`, `allowagentforwarding no`. app01: same values for the keys read.
Drop-ins on both: `01-pca-hardening.conf`, `50-redhat.conf` (LogSentinel files removed, backups in `/root/pca-backup/sshd_config.d/`).

### 4.10 keepalived

Not deployed (single LB VM). Production treatment in section 8.

### 4.11 Scenario tooling

**`scenarios/lib.sh`**

```bash
#!/bin/bash
# Shared helpers for the PCA demo scenarios (sourced, not executed).
set -euo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$LAB/.secrets"
export BASE=https://odoo.pca.lab
export PCA_HDR_NAME="$LOADTEST_HEADER_NAME" PCA_HDR_VALUE="$LOADTEST_HEADER_VALUE"
export PCA_PW1="$VENDEUR1_PASSWORD" PCA_PW2="$VENDEUR2_PASSWORD"
RAW="$LAB/results/raw"; mkdir -p "$RAW"
TS=$(date +%Y%m%d-%H%M%S)
now_ms(){ date +%s%3N; }
log(){ echo "[$(date +%H:%M:%S.%3N)] $*"; }
app(){ ssh -q app01 "$@" </dev/null; }
lbx(){ ssh -q lb01 "$@" </dev/null; }
# HAProxy runtime API (admin socket on lb01)
hap(){ ssh -q lb01 "echo '$*' | sudo socat stdio /run/haproxy/admin.sock" </dev/null; }
# show stat columns: 1 pxname 2 svname 5 scur 8 stot 14 econ 15 eresp 16 wretr 17 wredis 18 status 24 lastchg
srv_field(){ hap "show stat" | awk -F, -v b="$1" -v s="$2" -v f="$3" '$1==b && $2==s {print $f}'; }
srv_status(){ srv_field "$1" "$2" 18; }
wait_status(){ # backend server regex timeout_s -> waits until status matches, prints elapsed ms
  local b=$1 s=$2 re=$3 to=${4:-120} t0; t0=$(now_ms)
  while :; do st=$(srv_status "$b" "$s"); [[ "$st" =~ $re ]] && { echo $(( $(now_ms) - t0 )); return 0; }
    (( $(now_ms) - t0 > to*1000 )) && { echo "TIMEOUT($st)"; return 1; }; sleep 0.25; done; }
container_healthy(){ app "sudo docker inspect -f '{{.State.Health.Status}}' $1" 2>/dev/null; }
wait_healthy(){ local c=$1 to=${2:-180} t0; t0=$(now_ms)
  while [ "$(container_healthy "$c")" != healthy ]; do (( $(now_ms) - t0 > to*1000 )) && return 1; sleep 1; done; echo $(( $(now_ms) - t0 )); }
k6run(){ # name vus duration think [extra k6 args...]
  local name=$1 vus=$2 dur=$3 think=$4; shift 4
  VUS=$vus DURATION=$dur THINK=$think SUMMARY="$RAW/${name}_k6.json" k6 run --quiet --no-color "$@" "$LAB/scenarios/k6/odoo_load.js"; }
k6json(){ # file -> "reqs rps p95 failed_rate failed_count rpc_errors"
  python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))["metrics"]
g=lambda m,k,default=0: d.get(m,{}).get("values",{}).get(k,default)
print(int(g("http_reqs","count")), round(g("http_reqs","rate"),1), round(g("http_req_duration","p(95)"),1), round(g("http_req_failed","rate"),5), int(g("http_req_failed","passes")), int(g("rpc_errors","count")))' "$1"; }
# Warm a node before it takes traffic: direct requests from lb01 (the only host allowed to reach the backends)
# load templates, registry and caches in BOTH workers, so the first real users and health checks are not slow.
warm_node(){ # n = 1..3
  local port=$(( 8069 + ($1 - 1) * 100 ))
  ssh -q lb01 "PW='$PCA_PW1' P=$port bash -s" <<'W'
for i in 1 2 3 4; do curl -s -o /dev/null -m 60 -H 'Host: odoo.pca.lab' http://192.168.100.10:$P/web/login & done; wait
for i in 1 2 3 4; do (j=$(mktemp); curl -s -o /dev/null -m 60 -c $j -H 'Host: odoo.pca.lab' -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"params\":{\"db\":\"pca_demo\",\"login\":\"vendeur1\",\"password\":\"$PW\"}}" http://192.168.100.10:$P/web/session/authenticate
  curl -s -o /dev/null -m 60 -b $j -H 'Host: odoo.pca.lab' http://192.168.100.10:$P/web; shred -u $j) & done; wait
W
}
```

**`scenarios/probe.py`**

```python
#!/usr/bin/env python3
"""User-like probe: logs in once through the LB, then sends one authenticated JSON-RPC call every INTERVAL s.
Logs per request: epoch_ms, http status, latency, backend server (X-PCA-Server), SRV cookie, ok, error.
Usage: python3 -I probe.py --duration 90 --out file.csv [--pin odoo1] [--interval 0.2]"""
import argparse, json, os, ssl, sys, time, http.client, http.cookies, urllib.parse

ap = argparse.ArgumentParser()
ap.add_argument('--duration', type=float, default=60)
ap.add_argument('--interval', type=float, default=0.2)
ap.add_argument('--out', required=True)
ap.add_argument('--pin', default=None, help='initial SRV cookie (e.g. odoo1) so the probe starts on that node')
ap.add_argument('--login', default='vendeur2')
ap.add_argument('--close', action='store_true', help='send Connection: close on every request (default: keep-alive like a browser)')
a = ap.parse_args()
BASE = os.environ.get('BASE', 'https://odoo.pca.lab')
HDR = {os.environ['PCA_HDR_NAME']: os.environ['PCA_HDR_VALUE'], 'Content-Type': 'application/json'}
PW = os.environ['PCA_PW2'] if a.login == 'vendeur2' else os.environ['PCA_PW1']
ctx = ssl.create_default_context()
cookies = {}
if a.pin:
    cookies['SRV'] = a.pin

U = urllib.parse.urlsplit(BASE)
conn = None

def post(path, payload, timeout=15):
    """One HTTP/1.1 request on a persistent TLS connection (browser-like). A failed request is NOT retried here:
    the error is reported, and the next request opens a new connection."""
    global conn
    h = dict(HDR)
    if a.close:
        h['Connection'] = 'close'
    if cookies:
        h['Cookie'] = '; '.join(f'{k}={v}' for k, v in cookies.items())
    t0 = time.time()
    try:
        if conn is None:
            conn = http.client.HTTPSConnection(U.hostname, U.port or 443, timeout=timeout, context=ctx)
        conn.request('POST', path, body=json.dumps(payload).encode(), headers=h)
        r = conn.getresponse()
        status, body, hdrs = r.status, r.read(), r.headers
        if a.close or r.will_close:
            conn.close(); conn = None
    except Exception:
        if conn is not None:
            conn.close()
        conn = None
        raise
    lat = (time.time() - t0) * 1000
    for sc in hdrs.get_all('Set-Cookie') or []:
        c = http.cookies.SimpleCookie(); c.load(sc)
        for k, m in c.items():
            cookies[k] = m.value
    return status, body, hdrs.get('X-PCA-Server', ''), lat

st, body, srv, lat = post('/web/session/authenticate', {'jsonrpc': '2.0', 'params': {'db': 'pca_demo', 'login': a.login, 'password': PW}})
uid = json.loads(body).get('result', {}).get('uid')
if not uid:
    print('PROBE LOGIN FAILED', st, file=sys.stderr); sys.exit(2)
print(f'probe: logged in as {a.login} uid={uid} on {srv}', file=sys.stderr)
rows, end, nxt = [], time.time() + a.duration, time.time()
payload = {'jsonrpc': '2.0', 'method': 'call', 'params': {'model': 'sale.order', 'method': 'search_count', 'args': [[]], 'kwargs': {}}}
with open(a.out, 'w') as f:
    f.write('epoch_ms,status,latency_ms,server,srv_cookie,ok,error\n')
    while time.time() < end:
        ts = int(time.time() * 1000)
        err = ''
        try:
            st, body, srv, lat = post('/web/dataset/call_kw/sale.order/search_count', payload)
            j = json.loads(body) if st == 200 else {}
            ok = st == 200 and isinstance(j.get('result'), int)
            if not ok:
                err = (j.get('error', {}).get('data', {}).get('name') or f'http_{st}')[:60]
        except Exception as e:  # network error = user-visible failure
            st, srv, lat, ok, err = 0, '', 0, False, type(e).__name__
        f.write(f'{ts},{st},{lat:.1f},{srv},{cookies.get("SRV","")},{int(ok)},{err}\n'); f.flush()
        nxt += a.interval
        time.sleep(max(0, nxt - time.time()))
```

**`scenarios/probe_summary.py`**

```python
#!/usr/bin/env python3
"""Summarise a probe CSV: total, failed, max gap between two successful answers, server transitions, p95 latency."""
import csv, json, sys
rows = list(csv.DictReader(open(sys.argv[1])))
ok = [r for r in rows if r['ok'] == '1']
fail = [r for r in rows if r['ok'] != '1']
gaps = [int(b['epoch_ms']) - int(a['epoch_ms']) for a, b in zip(ok, ok[1:])]
trans, prev = [], None
for r in rows:
    if r['server'] and r['server'] != prev:
        trans.append((int(r['epoch_ms']), r['server'])); prev = r['server']
lat = sorted(float(r['latency_ms']) for r in ok)
p95 = lat[int(len(lat) * 0.95) - 1] if lat else 0
out = {'total': len(rows), 'failed': len(fail), 'failed_pct': round(100 * len(fail) / max(1, len(rows)), 3),
       'max_gap_ms': max(gaps) if gaps else None, 'p95_ms': round(p95, 1), 'max_latency_ms': round(lat[-1], 1) if lat else None,
       'server_transitions': trans, 'errors': sorted({r['error'] for r in fail})}
print(json.dumps(out))
```

**`scenarios/k6/odoo_load.js`**

```javascript
// PCA lab - realistic Odoo sales user load through the load balancer.
// Each VU logs in once (vendeur1/vendeur2), then loops: list sales orders, list customers, list products, open the web client.
// Env: BASE VUS DURATION THINK SUMMARY PCA_HDR_NAME PCA_HDR_VALUE PCA_PW1 PCA_PW2
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const BASE = __ENV.BASE || 'https://odoo.pca.lab';
const HDR = { 'Content-Type': 'application/json' };
HDR[__ENV.PCA_HDR_NAME] = __ENV.PCA_HDR_VALUE;          // rate-limit exemption (secret, stripped by HAProxy)
const THINK = parseFloat(__ENV.THINK || '0.5');
const rpcErrors = new Counter('rpc_errors');
const businessOk = new Rate('business_ok');

export const options = {
  scenarios: { load: { executor: 'constant-vus', vus: parseInt(__ENV.VUS || '5'), duration: __ENV.DURATION || '60s' } },
  noCookiesReset: true,   // keep session + SRV cookie across iterations, like a real browser (k6 resets the jar by default)
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: { http_req_failed: ['rate<0.01'] },
};

function rpc(model, method, args, kwargs) {
  const body = JSON.stringify({ jsonrpc: '2.0', method: 'call', params: { model, method, args, kwargs } });
  const r = http.post(`${BASE}/web/dataset/call_kw/${model}/${method}`, body, { headers: HDR, tags: { name: `${model}.${method}` } });
  let ok = r.status === 200;
  if (ok) { try { const j = r.json(); ok = j.result !== undefined && !j.error; } catch (e) { ok = false; } }
  if (!ok) rpcErrors.add(1);
  businessOk.add(ok);
  return r;
}

function login() {
  const user = __VU % 2 ? 'vendeur1' : 'vendeur2';
  const pw = user === 'vendeur1' ? __ENV.PCA_PW1 : __ENV.PCA_PW2;
  const r = http.post(`${BASE}/web/session/authenticate`,
    JSON.stringify({ jsonrpc: '2.0', params: { db: 'pca_demo', login: user, password: pw } }),
    { headers: HDR, tags: { name: 'authenticate' } });
  const ok = check(r, { 'login ok': (x) => x.status === 200 && !!x.json('result.uid') });
  businessOk.add(ok);
  if (!ok) rpcErrors.add(1);
}

export default function () {
  if (__ITER === 0) login();
  rpc('sale.order', 'search_read', [[]], { fields: ['name', 'partner_id', 'amount_total', 'state', 'date_order'], limit: 20, order: 'date_order desc' });
  rpc('res.partner', 'search_read', [[['is_company', '=', true]]], { fields: ['name', 'email', 'city', 'country_id'], limit: 20 });
  rpc('product.product', 'search_read', [[['sale_ok', '=', true]]], { fields: ['name', 'list_price', 'default_code'], limit: 20 });
  const p = http.get(`${BASE}/web`, { headers: { [__ENV.PCA_HDR_NAME]: __ENV.PCA_HDR_VALUE }, tags: { name: 'page /web' } });
  const ok = check(p, { 'web client 200': (x) => x.status === 200 });
  businessOk.add(ok);
  if (THINK > 0) sleep(THINK);
}

export function handleSummary(data) {
  const m = data.metrics, v = (k, f) => (m[k] && m[k].values[f] !== undefined ? m[k].values[f] : 0);
  const line = `k6: reqs=${v('http_reqs', 'count')} rps=${v('http_reqs', 'rate').toFixed(1)} p95=${v('http_req_duration', 'p(95)').toFixed(1)}ms ` +
    `failed=${v('http_req_failed', 'passes')} (${(100 * v('http_req_failed', 'rate')).toFixed(3)}%) rpc_errors=${v('rpc_errors', 'count')}\n`;
  const out = { stdout: line };
  if (__ENV.SUMMARY) out[__ENV.SUMMARY] = JSON.stringify(data, null, 1);
  return out;
}
```

Choices: login once per VU (like a real user) with `noCookiesReset`; business success checked in the JSON body (Odoo returns
errors with HTTP 200); the exemption header so the test measures the application, not the limiter.

**`scenarios/k6/browser_session.js`**

```javascript
// Real browser (Chromium via k6/browser): login form -> web client -> Sales orders list.
// Used to size the rate limit (how many requests does a real user page load generate?).
import { browser } from 'k6/browser';
export const options = { scenarios: { ui: { executor: 'shared-iterations', iterations: 1, options: { browser: { type: 'chromium' } } } } };
export default async function () {
  const page = await browser.newPage();
  try {
    await page.goto(`${__ENV.BASE}/web/login`, { waitUntil: 'networkidle' });
    await page.locator('input[name="login"]').type('vendeur1');
    await page.locator('input[name="password"]').type(__ENV.PCA_PW1);
    await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle' }), page.locator('button[type="submit"]').click()]);
    console.log('MARK logged-in url=' + page.url());
    await page.goto(`${__ENV.BASE}/web#action=sale.action_orders`, { waitUntil: "networkidle" });
    await page.locator(".o_list_view, .o_kanban_view").waitFor({ timeout: 15000 });
    await page.waitForTimeout(1500);
    console.log('MARK sales url=' + page.url());
    await page.screenshot({ path: __ENV.SHOT || 'sales.png' });
  } finally { await page.close(); }
}
```

**`scenarios/reset_lab.sh`**

```bash
#!/bin/bash
# Bring the lab back to a known state: all containers up + healthy, every HAProxy server READY and UP, stick-table cleared.
source "$(dirname "$0")/lib.sh"
log "reset: docker compose up -d on app01"
app "cd /opt/pca-odoo && sudo docker compose up -d 2>&1 | tail -1" || true
for c in pca-db odoo-1 odoo-2 odoo-3; do t=$(wait_healthy $c 240) || { echo "RESET FAILED: $c not healthy"; exit 1; }; done
for b in be_odoo be_odoo_ws; do for s in odoo1 odoo2 odoo3; do hap "set server $b/$s state ready" >/dev/null; done; done
for b in be_odoo be_odoo_ws; do for s in odoo1 odoo2 odoo3; do wait_status $b $s '^UP$' 60 >/dev/null || { echo "RESET FAILED: $b/$s $(srv_status $b $s)"; exit 1; }; done; done
for n in 1 2 3; do warm_node $n; done      # cold nodes after a restart answer slowly at first
hap "clear table fe_https" >/dev/null
hap "clear counters" >/dev/null
echo "RESET OK: 4 containers healthy, 6/6 HAProxy servers UP, stick-table cleared ($(date +%T))"
```

**`scenarios/s1_node_failure.sh`**

```bash
#!/bin/bash
# S1 - Node failure: a user probe (1 authenticated call / 200 ms, pinned to odoo1) + light k6 load,
# then odoo-1 is stopped (MODE=stop: docker stop, graceful) or crashed (MODE=kill: SIGKILL), kept down 25 s, restarted.
# Measures: HAProxy detection time, user-visible failures, longest user gap, session continuity, recovery time.
source "$(dirname "$0")/lib.sh"
MODE=${MODE:-stop}
# PROBE_ARGS=--close makes the probe send "Connection: close" (non-browser client), see DECISIONS.md
N=s1_${MODE}_$TS; OUT=$RAW/$N
"$LAB/scenarios/reset_lab.sh" | tail -1
log "S1 ($MODE): probe pinned on odoo1 + k6 5 VUs"
python3 -I "$LAB/scenarios/probe.py" --duration 95 --pin odoo1 ${PROBE_ARGS:-} --out ${OUT}_probe.csv 2>${OUT}_probe.log & P1=$!
k6run $N 5 90s 0.5 > ${OUT}_k6.txt 2>&1 & P2=$!
sleep 20
T0=$(now_ms); log "T0: docker $MODE odoo-1"
app "sudo docker $MODE odoo-1 >/dev/null" & PS=$!
DETECT=$(wait_status be_odoo odoo1 '^DOWN' 60); TD=$(now_ms)
wait $PS; TSTOP=$(( $(now_ms) - T0 ))
# when did the node really stop serving? (container exit, clocks NTP-synced)
FIN=$(app "sudo docker inspect -f '{{.State.FinishedAt}}' odoo-1")
FIN_MS=$(python3 -I -c 'import sys,datetime; t=sys.argv[1].rstrip("Z"); b,_,f=t.partition("."); print(int(datetime.datetime.fromisoformat(b+"."+(f+"000000")[:6]).replace(tzinfo=datetime.timezone.utc).timestamp()*1000))' "$FIN")
EXIT_MS=$(( FIN_MS - T0 )); DETECT_EXIT=$(( TD - FIN_MS ))
log "HAProxy marked be_odoo/odoo1 DOWN ${DETECT} ms after the command; the container exited at +${EXIT_MS} ms -> LB detection after exit = ${DETECT_EXIT} ms"
STAT_DOWN=$(hap "show stat" | awk -F, '$1=="be_odoo" {print $2, $18, "stot="$8, "econ="$14, "eresp="$15, "retries="$16, "redispatch="$17}')
sleep 25
T2=$(now_ms); log "restart odoo-1"
app "sudo docker start odoo-1 >/dev/null"
HEALTHY=$(wait_healthy odoo-1 240); UPMS=$(wait_status be_odoo odoo1 '^UP$' 120)
RECOV=$(( $(now_ms) - T2 ))
log "odoo-1 container healthy after ${HEALTHY} ms, back in rotation (UP) $RECOV ms after start"
wait $P1 $P2 || true
# HAProxy's own view of the transitions (journald, microsecond timestamps)
lbx "sudo journalctl -u haproxy --since @$(( T0/1000 - 2 )) -o short-iso-precise | grep -E 'Server be_odoo(_ws)?/odoo1 is (DOWN|UP)'" > ${OUT}_haproxy_transitions.log || true
LOGDOWN=$(grep -m1 'be_odoo/odoo1 is DOWN' ${OUT}_haproxy_transitions.log | awk '{print $1}')
LOGDETECT=$(python3 -I -c 'import sys,datetime; t=sys.argv[1]; print(int(datetime.datetime.fromisoformat(t).timestamp()*1000)-int(sys.argv[2])) if t else print("n/a")' "$LOGDOWN" "$T0")
PS_JSON=$(python3 -I "$LAB/scenarios/probe_summary.py" ${OUT}_probe.csv)
read -r REQS RPS P95 FRATE FCOUNT RPCERR < <(k6json $RAW/${N}_k6.json)
SESSION_LOST=$(grep -c SessionExpired ${OUT}_probe.csv || true)
python3 -I - "$PS_JSON" <<PY > ${OUT}_result.json
import json,sys
p=json.loads(sys.argv[1])
print(json.dumps({"scenario":"S1","mode":"$MODE","ts":"$TS","detect_ms_poll":int("$DETECT") if "$DETECT".isdigit() else "$DETECT","detect_ms_haproxy_log":"$LOGDETECT",
 "docker_cmd_ms":$TSTOP,"container_exit_ms":$EXIT_MS,"detect_after_exit_ms":$DETECT_EXIT,"recovery_container_healthy_ms":int("$HEALTHY" or 0),"recovery_back_in_lb_ms":$RECOV,
 "probe":p,"probe_session_expired":$SESSION_LOST,
 "k6":{"reqs":$REQS,"rps":$RPS,"p95_ms":$P95,"failed":$FCOUNT,"failed_rate":$FRATE,"rpc_errors":$RPCERR},
 "be_odoo_stats_while_down":"""$STAT_DOWN""".splitlines()},indent=1))
PY
FAILED_PCT=$(python3 -I -c 'import json,sys; p=json.loads(sys.argv[1]); print(p["failed_pct"])' "$PS_JSON")
MAXGAP=$(python3 -I -c 'import json,sys; p=json.loads(sys.argv[1]); print(p["max_gap_ms"])' "$PS_JSON")
TRANS=$(python3 -I -c 'import json,sys; p=json.loads(sys.argv[1]); print("->".join(s for _,s in p["server_transitions"]))' "$PS_JSON")
K6PCT=$(python3 -I -c "print(round(100*$FRATE,3))")
PASS=PASS
[[ "$DETECT" =~ ^[0-9]+$ ]] && (( DETECT_EXIT <= 9000 )) || PASS=FAIL
python3 -I -c "import sys; sys.exit(0 if $FAILED_PCT<=1 and $K6PCT<=1 else 1)" || PASS=FAIL
(( SESSION_LOST == 0 )) || PASS=FAIL
printf "S1\t%s\t%s\tdetect_after_exit_ms=%s\texit_ms=%s\tdetect_from_cmd_ms=%s\tdetect_log_ms=%s\tprobe_failed_pct=%s\tprobe_max_gap_ms=%s\tk6_failed=%s(%s%%)\tsession_lost=%s\trecovery_ms=%s\tservers=%s\t%s\n" \
  "$TS" "$MODE" "$DETECT_EXIT" "$EXIT_MS" "$DETECT" "$LOGDETECT" "$FAILED_PCT" "$MAXGAP" "$FCOUNT" "$K6PCT" "$SESSION_LOST" "$RECOV" "$TRANS" "$PASS" >> "$RAW/results.tsv"
echo "VERDICT S1[$MODE] $PASS: node stopped serving at +${EXIT_MS} ms, LB detection ${DETECT_EXIT} ms after that (${DETECT} ms after the command, HAProxy log ${LOGDETECT} ms), user probe failed ${FAILED_PCT}% max gap ${MAXGAP} ms, k6 failed ${FCOUNT} (${K6PCT}%), session lost ${SESSION_LOST}x, path ${TRANS}, back in LB ${RECOV} ms after restart"
```

**`scenarios/s2_rolling_update.sh`**

```bash
#!/bin/bash
# S2 - Rolling update without downtime. Under light load (k6 5 VUs + user probe), for each node in turn:
# drain (no new users, existing sessions finish) -> 0 current sessions -> maint -> recreate the container
# -> wait healthy -> ready -> wait HAProxy UP. Pass: 0 failed requests during the whole window.
source "$(dirname "$0")/lib.sh"
N=s2_$TS; OUT=$RAW/$N
"$LAB/scenarios/reset_lab.sh" | tail -1
log "S2: start probe + k6 (5 VUs)"
python3 -I "$LAB/scenarios/probe.py" --duration 900 --out ${OUT}_probe.csv 2>${OUT}_probe.log & P1=$!
k6run $N 5 900s 0.5 > ${OUT}_k6.txt 2>&1 & P2=$!
sleep 15
scur(){ srv_field be_odoo "$1" 5; }
wait_idle(){ local s=$1 to=$2 t0 z=0; t0=$(now_ms)
  while (( $(now_ms) - t0 < to*1000 )); do [ "$(scur $s)" = 0 ] && z=$((z+1)) || z=0; (( z >= 2 )) && break; sleep 0.25; done
  echo $(( $(now_ms) - t0 )); }
echo -e "node\tdrain_to_idle_ms\trecreate_to_healthy_ms\tready_to_UP_ms\tnode_total_ms\told_container\tnew_container" > ${OUT}_steps.tsv
TSTART=$(now_ms)
for n in 1 2 3; do
  s=odoo$n; c=odoo-$n; t0=$(now_ms)
  OLD=$(app "sudo docker inspect -f '{{.Id}}' $c" | cut -c1-12)
  log "[$s] drain"; for b in be_odoo be_odoo_ws; do hap "set server $b/$s state drain" >/dev/null; done
  D=$(wait_idle $s 30)
  log "[$s] idle after $D ms -> maint"; for b in be_odoo be_odoo_ws; do hap "set server $b/$s state maint" >/dev/null; done
  wait_idle $s 10 >/dev/null
  log "[$s] recreate container $c (simulated update)"; t1=$(now_ms)
  app "cd /opt/pca-odoo && sudo docker compose up -d --no-deps --force-recreate $c 2>&1 | tail -1" >/dev/null
  H=$(wait_healthy $c 240); NEW=$(app "sudo docker inspect -f '{{.Id}}' $c" | cut -c1-12)
  warm_node $n
  log "[$s] healthy after $H ms (container $OLD -> $NEW), warmed up -> ready"
  for b in be_odoo be_odoo_ws; do hap "set server $b/$s state ready" >/dev/null; done
  U=$(wait_status be_odoo $s '^UP$' 120); wait_status be_odoo_ws $s '^UP$' 120 >/dev/null
  log "[$s] UP in HAProxy after $U ms"
  echo -e "$s\t$D\t$H\t$U\t$(( $(now_ms) - t0 ))\t$OLD\t$NEW" >> ${OUT}_steps.tsv
  sleep 5
done
TOTAL=$(( $(now_ms) - TSTART ))
sleep 10
kill -INT $P2 2>/dev/null; kill $P1 2>/dev/null; wait $P2 2>/dev/null || true; wait $P1 2>/dev/null || true
PS_JSON=$(python3 -I "$LAB/scenarios/probe_summary.py" ${OUT}_probe.csv)
read -r REQS RPS P95 FRATE FCOUNT RPCERR < <(k6json $RAW/${N}_k6.json)
PF=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["failed"])' "$PS_JSON")
PT=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["total"])' "$PS_JSON")
GAP=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["max_gap_ms"])' "$PS_JSON")
TRANS=$(python3 -I -c 'import json,sys; print("->".join(s for _,s in json.loads(sys.argv[1])["server_transitions"]))' "$PS_JSON")
PASS=PASS; (( PF == 0 && FCOUNT == 0 && RPCERR == 0 )) || PASS=FAIL
python3 -I -c 'import json,sys; print(json.dumps({"scenario":"S2","ts":sys.argv[1],"window_ms":int(sys.argv[2]),"probe":json.loads(sys.argv[3]),"k6":{"reqs":int(sys.argv[4]),"rps":float(sys.argv[5]),"p95_ms":float(sys.argv[6]),"failed":int(sys.argv[7]),"rpc_errors":int(sys.argv[8])},"steps":open(sys.argv[9]).read().splitlines()},indent=1))' \
  "$TS" "$TOTAL" "$PS_JSON" "$REQS" "$RPS" "$P95" "$FCOUNT" "$RPCERR" ${OUT}_steps.tsv > ${OUT}_result.json
printf "S2\t%s\trolling\twindow_ms=%s\tk6_reqs=%s\tk6_failed=%s\trpc_errors=%s\tprobe=%s/%s_failed\tprobe_max_gap_ms=%s\tk6_p95=%s\tservers=%s\t%s\n" "$TS" "$TOTAL" "$REQS" "$FCOUNT" "$RPCERR" "$PF" "$PT" "$GAP" "$P95" "$TRANS" "$PASS" >> "$RAW/results.tsv"
column -t ${OUT}_steps.tsv
echo "VERDICT S2 $PASS: 3 nodes replaced one by one in $((TOTAL/1000)) s; k6 ${REQS} requests, ${FCOUNT} failed, ${RPCERR} RPC errors; user probe ${PF}/${PT} failed, max gap ${GAP} ms, path ${TRANS}"
```

**`scenarios/s3_scaleout.sh`**

```bash
#!/bin/bash
# S3 - Scale-out: identical closed-loop k6 profile, first with only odoo1 in service (odoo2/3 in maint), then with 3 nodes.
# Reports req/s, p95, error rate, per-server request split, app01 CPU (2 vCPU) and kali CPU (load generator) during each run.
# CPU_PER_NODE=0.66 caps each Odoo container (docker update, reverted at the end) to emulate 3 independent small nodes
# instead of 3 containers sharing the same 2 vCPU. Default: no cap (= the real lab).
source "$(dirname "$0")/lib.sh"
VUS=${VUS:-12}; DUR=${DUR:-60s}; THINK=${THINK:-0}; CPU_PER_NODE=${CPU_PER_NODE:-}
VARIANT=${CPU_PER_NODE:+capped${CPU_PER_NODE}cpu}; VARIANT=${VARIANT:-shared}
N=s3_${VARIANT}_$TS; OUT=$RAW/$N
restore_cpu(){ app "sudo docker update --cpus 2 odoo-1 odoo-2 odoo-3 >/dev/null"; }
trap restore_cpu EXIT
cpu_sample(){ app "head -1 /proc/stat"; }
cpu_busy(){ python3 -I -c 'import sys
a=list(map(int,sys.argv[1].split()[1:])); b=list(map(int,sys.argv[2].split()[1:]))
d=[y-x for x,y in zip(a,b)]; idle=d[3]+d[4]; print(round(100*(sum(d)-idle)/sum(d),1))' "$1" "$2"; }
stot(){ hap "show stat" | awk -F, '$1=="be_odoo" && $2 ~ /^odoo/ {printf "%s=%s ", $2, $8}'; }
run(){ local label=$1
  hap "clear counters all" >/dev/null
  local c0; c0=$(cpu_sample); local k0; k0=$(head -1 /proc/stat)
  k6run ${N}_$label $VUS $DUR $THINK > ${OUT}_${label}_k6.txt 2>&1 || true
  local c1; c1=$(cpu_sample); local k1; k1=$(head -1 /proc/stat)
  local busy; busy=$(cpu_busy "$c0" "$c1"); local kbusy; kbusy=$(cpu_busy "$k0" "$k1")
  read -r REQS RPS P95 FRATE FCOUNT RPCERR < <(k6json $RAW/${N}_${label}_k6.json)
  local split; split=$(stot)
  local OKRPS; OKRPS=$(python3 -I -c "import json,sys; d=json.load(open(sys.argv[1]))['state']['testRunDurationMs']; print(round(($REQS-$FCOUNT)/(d/1000),1))" $RAW/${N}_${label}_k6.json)
  echo "$label ok_rps=$OKRPS rps=$RPS p95_ms=$P95 reqs=$REQS failed=$FCOUNT rpc_errors=$RPCERR app01_cpu_busy=${busy}% kali_cpu_busy=${kbusy}% split: $split" | tee -a ${OUT}_summary.txt
  eval "R_${label}_OK=$OKRPS; R_${label}_RPS=$RPS; R_${label}_P95=$P95; R_${label}_ERR=$FRATE; R_${label}_CPU=$busy"
}
"$LAB/scenarios/reset_lab.sh" | tail -1
app "echo nproc=\$(nproc); free -m | head -2" | tee ${OUT}_host.txt
if [ -n "$CPU_PER_NODE" ]; then app "sudo docker update --cpus $CPU_PER_NODE odoo-1 odoo-2 odoo-3 >/dev/null"; log "variant: each Odoo container capped to $CPU_PER_NODE vCPU"; fi
app "sudo docker inspect -f '{{.Name}} NanoCpus={{.HostConfig.NanoCpus}}' odoo-1 odoo-2 odoo-3" >> ${OUT}_host.txt
log "S3 run A: only odoo1 in service (odoo2, odoo3 -> maint), $VUS VUs, think ${THINK}s, $DUR"
for s in odoo2 odoo3; do for b in be_odoo be_odoo_ws; do hap "set server $b/$s state maint" >/dev/null; done; done
sleep 3; k6run warmup_$TS 4 15s 0 >/dev/null 2>&1 || true
run 1node
app "top -b -n1 -o %CPU | head -15" > ${OUT}_1node_top.txt
log "S3 run B: all 3 nodes"
for s in odoo2 odoo3; do for b in be_odoo be_odoo_ws; do hap "set server $b/$s state ready" >/dev/null; done; done
for s in odoo2 odoo3; do wait_status be_odoo $s '^UP$' 60 >/dev/null; done
sleep 3; k6run warmup_$TS 4 15s 0 >/dev/null 2>&1 || true
run 3nodes
app "top -b -n1 -o %CPU | head -15" > ${OUT}_3nodes_top.txt
GAIN=$(python3 -I -c "print(round($R_3nodes_OK/max($R_1node_OK,0.1),2))")
P95R=$(python3 -I -c "print(round($R_3nodes_P95/$R_1node_P95,2))")
printf "S3\t%s\t%s\tVUs=%s,think=%s,%s\t1node_ok_rps=%s\t1node_rps=%s\t1node_p95=%s\t1node_err=%s\t1node_cpu=%s%%\t3nodes_ok_rps=%s\t3nodes_rps=%s\t3nodes_p95=%s\t3nodes_err=%s\t3nodes_cpu=%s%%\tgain=x%s\tp95_ratio=%s\n" \
  "$TS" "$VARIANT" "$VUS" "$THINK" "$DUR" "$R_1node_OK" "$R_1node_RPS" "$R_1node_P95" "$R_1node_ERR" "$R_1node_CPU" "$R_3nodes_OK" "$R_3nodes_RPS" "$R_3nodes_P95" "$R_3nodes_ERR" "$R_3nodes_CPU" "$GAIN" "$P95R" >> "$RAW/results.tsv"
echo "VERDICT S3[$VARIANT] DONE: 1 node ${R_1node_OK} successful req/s (raw ${R_1node_RPS}, error rate ${R_1node_ERR}) p95 ${R_1node_P95} ms (app01 CPU ${R_1node_CPU}%) -> 3 nodes ${R_3nodes_OK} successful req/s (error rate ${R_3nodes_ERR}) p95 ${R_3nodes_P95} ms (CPU ${R_3nodes_CPU}%): successful throughput x${GAIN}, p95 x${P95R} (app01 has $(app nproc) vCPU)"
```

**`scenarios/s4_rate_limit.sh`**

```bash
#!/bin/bash
# S4 - Rate limiting at the edge: a burst from kali WITHOUT the exemption header must get 429 above the threshold,
# the backend must not see the excess, the exempt load-test client is not throttled, and normal browsing works afterwards.
source "$(dirname "$0")/lib.sh"
BURST=${BURST:-600}; PAR=${PAR:-20}
N=s4_$TS; OUT=$RAW/$N
LIMIT=$(lbx "sudo grep -oP 'sc_http_req_rate\(0\) gt \K[0-9]+' /etc/haproxy/haproxy.cfg")
"$LAB/scenarios/reset_lab.sh" | tail -1
B0=$(srv_field be_odoo BACKEND 8)
log "S4: burst of $BURST GET /web/login, $PAR in parallel, no exemption header (limit: $LIMIT req / 10 s / IP)"
T0=$(now_ms)
seq 1 $BURST | xargs -P $PAR -I{} curl -sS -o /dev/null -w '%{http_code}\n' $BASE/web/login > ${OUT}_burst_codes.txt
DT=$(( $(now_ms) - T0 ))
B1=$(srv_field be_odoo BACKEND 8)
TABLE=$(hap "show table fe_https" | grep -E "192.168.100.30|table:")
C200=$(grep -c '^200$' ${OUT}_burst_codes.txt || true); C429=$(grep -c '^429$' ${OUT}_burst_codes.txt || true)
FIRST429=$(grep -n '^429$' ${OUT}_burst_codes.txt | head -1 | cut -d: -f1 || true); FIRST429=${FIRST429:-none}
OTHER=$(grep -vcE '^(200|429)$' ${OUT}_burst_codes.txt || true)
log "burst done in $DT ms: 200=$C200 429=$C429 other=$OTHER, first 429 at response #$FIRST429; backend received $((B1-B0)) requests"
log "stick-table entry: $TABLE"
log "same burst size from the exempt test client (secret header): "
EX=$(seq 1 300 | xargs -P $PAR -I{} curl -sS -o /dev/null -w '%{http_code}\n' -H "$PCA_HDR_NAME: $PCA_HDR_VALUE" $BASE/web/login | sort | uniq -c | tr '\n' ' ')
log "   exempt 300 requests -> $EX"
WRONG=$(seq 1 150 | xargs -P 10 -I{} curl -sS -o /dev/null -w '%{http_code}\n' -H "$PCA_HDR_NAME: guessed-value" $BASE/web/login | sort | uniq -c | tr '\n' ' ')
log "   wrong header value, 150 requests (tracked like any client -> throttled above the limit) -> $WRONG"
log "wait 11 s for the 10 s window to slide, then browse normally (GET login page, POST login, open web client)"
sleep 11
J=$RAW/.s4.jar; P=$RAW/.s4.page; : > $J
A=$(curl -sS -c $J -b $J -o $P -w '%{http_code}' $BASE/web/login)
CSRF=$(grep -oP 'name="csrf_token" value="\K[^"]+' $P)
B=$(curl -sS -c $J -b $J -o /dev/null -w '%{http_code}' --data-urlencode "csrf_token=$CSRF" --data-urlencode login=vendeur1 --data-urlencode "password=$PCA_PW1" $BASE/web/login)
C=$(curl -sS -b $J -o /dev/null -w '%{http_code}' $BASE/web)
: > $J; : > $P   # do not keep session cookies on disk
log "after the burst: GET /web/login=$A POST /web/login=$B GET /web=$C"
lbx "sudo journalctl -u haproxy --since @$(( T0/1000 )) -o cat | grep ' 429 ' | head -3" > ${OUT}_429_log_sample.txt
PASS=PASS; (( C429 > 0 )) && echo "$WRONG" | grep -q 429 && [ "$A" = 200 ] && [ "$B" = 303 ] && [ "$C" = 200 ] && ! echo "$EX" | grep -q 429 || PASS=FAIL
printf "S4\t%s\tburst=%s/par%s\tlimit=%s\t200=%s\t429=%s\tother=%s\tfirst429=#%s\tbackend_saw=%s\texempt=%s\tafter=%s/%s/%s\t%s\n" "$TS" "$BURST" "$PAR" "$LIMIT" "$C200" "$C429" "$OTHER" "$FIRST429" "$((B1-B0))" "$(echo $EX | tr ' ' '_')" "$A" "$B" "$C" "$PASS" >> "$RAW/results.tsv"
echo "VERDICT S4 $PASS: $BURST-request burst -> $C200 x 200, $C429 x 429 (first at #$FIRST429, limit $LIMIT/10s), backend saw only $((B1-B0)); exempt client: $EX; normal login afterwards $A/$B/$C"
```

**`scenarios/s5_lb_visibility.sh`**

```bash
#!/bin/bash
# S5 - Observability: snapshot stats CSV/HTML/Prometheus, then a "hung node" (docker pause odoo-3: process frozen,
# TCP still accepted by the kernel) and its recovery, recorded from the runtime API (timeline), the logs and the metrics.
source "$(dirname "$0")/lib.sh"
N=s5_$TS; OUT=$RAW/$N
"$LAB/scenarios/reset_lab.sh" | tail -1
AUTH="$HAPROXY_STATS_USER:$HAPROXY_STATS_PASSWORD"
hap "show stat" > ${OUT}_stats_before.csv
curl -sS -u "$AUTH" "http://lb01:8404/stats" > ${OUT}_stats_page.html
curl -sS -u "$AUTH" "http://lb01:8404/stats;csv" > ${OUT}_stats_http.csv
curl -sS "http://lb01:8404/metrics" | grep -E '^haproxy_server_(status|check_status|up)\{' | grep be_odoo > ${OUT}_metrics_before.txt || true
log "S5: freeze odoo-3 (docker pause) and record the state machine every 0.5 s"
echo "t_ms,status,check_status,check_duration,lastchg_s" > ${OUT}_timeline.csv
poll(){ hap "show stat" | awk -F, -v t=$(( $(now_ms) - T0 )) '$1=="be_odoo" && $2=="odoo3" {print t","$18","$37","$38","$24}' >> ${OUT}_timeline.csv; }
T0=$(now_ms); app "sudo docker pause odoo-3 >/dev/null"
until grep -q ',DOWN,' ${OUT}_timeline.csv; do poll; sleep 0.5; (( $(now_ms) - T0 > 60000 )) && break; done
DET=$(grep -m1 ',DOWN,' ${OUT}_timeline.csv | cut -d, -f1)
DOWNSNAP=$(hap "show stat" | awk -F, '$1 ~ /be_odoo/ && $2 ~ /odoo/ {print $1"/"$2, $18, $37}')
curl -sS "http://lb01:8404/metrics" | grep -E '^haproxy_server_(status|check_status|up)\{' | grep be_odoo > ${OUT}_metrics_down.txt || true
log "odoo3 DOWN after $DET ms (hang = health checks time out). Unpause."
T1=$(now_ms); app "sudo docker unpause odoo-3 >/dev/null"
until [ "$(tail -1 ${OUT}_timeline.csv | cut -d, -f2)" = UP ]; do poll; sleep 0.5; (( $(now_ms) - T0 > 120000 )) && break; done
REC=$(( $(now_ms) - T1 ))
log "odoo3 UP again $REC ms after unpause"
lbx "sudo journalctl -u haproxy --since @$(( T0/1000 - 1 )) -o short-iso-precise | grep -v WARNING | grep -E 'Server be_odoo(_ws)?/odoo3 is'" > ${OUT}_haproxy_transitions.log || true
hap "show stat" > ${OUT}_stats_after.csv
SEQ=$(cut -d, -f2,3 ${OUT}_timeline.csv | tail -n +2 | uniq | tr '\n' ' ')
NLOG=$(wc -l < ${OUT}_haproxy_transitions.log)
PASS=PASS; [ -n "$DET" ] && grep -q ',DOWN,' ${OUT}_timeline.csv && (( NLOG >= 2 )) && grep -q 'odoo3' ${OUT}_metrics_down.txt || PASS=FAIL
printf "S5\t%s\thang(docker pause)\tdetect_ms=%s\trecovery_ms=%s\tlog_transitions=%s\tstates=%s\t%s\n" "$TS" "$DET" "$REC" "$NLOG" "$(echo $SEQ | tr ' ' '|')" "$PASS" >> "$RAW/results.tsv"
echo "--- while DOWN:"; echo "$DOWNSNAP"; echo "--- log:"; cut -c1-200 ${OUT}_haproxy_transitions.log
echo "VERDICT S5 $PASS: hung node detected DOWN in $DET ms, back UP $REC ms after unpause; state sequence: $SEQ; $NLOG log transitions; stats CSV/HTML + Prometheus captured"
```

**`scenarios/s6_db_failover.sh`**

```bash
#!/bin/bash
# S6 (phase 6) - Database tier: replication lag (RPO) and manual promotion of the streaming replica (RTO).
#  1. measure replication lag under a steady write load (separate database rpo_test, Odoo data untouched)
#  2. crash the primary (docker kill pca-db) -> compare last acknowledged write vs last replicated row (= RPO)
#  3. promote the replica (pg_promote) and give it the DNS name "db" on the Docker network -> Odoo reconnects (= RTO)
#  4. restore: discard the promoted replica, restart the original primary, rebuild a fresh replica
# Note: Odoo writes made during the failover window (logs, sessions) are discarded at step 4 (lab only).
source "$(dirname "$0")/lib.sh"
N=s6_$TS; OUT=$RAW/$N
NET=pca-odoo_backend
psqlp(){ app "sudo docker exec -i pca-db psql -U odoo -tAq $*"; }
psqlr(){ app "sudo docker exec -i pca-db-replica psql -U odoo -tAq $*"; }
"$LAB/scenarios/reset_lab.sh" | tail -1
[ "$(container_healthy pca-db-replica)" = healthy ] || { echo "replica not healthy"; exit 1; }
STATE=$(psqlp -d postgres -c "\"select state from pg_stat_replication where application_name<>'' limit 1\"")
log "replication state on primary: $STATE"
[ "$STATE" = streaming ] || { echo "replica not streaming"; exit 1; }
psqlp -d postgres -c "\"select 1 from pg_database where datname='rpo_test'\"" | grep -q 1 || psqlp -d postgres -c "\"create database rpo_test\""
psqlp -d rpo_test -c "\"create table if not exists t(id bigserial primary key, ts timestamptz not null default clock_timestamp())\""
log "1) steady write load: 1 insert every ~20 ms on the primary, sampling replication lag"
# writer inside the primary container: prints every acknowledged id with its commit timestamp
app "sudo docker exec pca-db bash -c 'while true; do psql -U odoo -d rpo_test -tAqc \"insert into t default values returning id, extract(epoch from ts)*1000\" || exit 0; sleep 0.02; done'" > ${OUT}_writer_acks.txt 2>/dev/null & W=$!
python3 -I "$LAB/scenarios/probe.py" --duration 400 --out ${OUT}_probe.csv 2>${OUT}_probe.log & P=$!
echo "t,write_lag,flush_lag,replay_lag,lag_bytes" > ${OUT}_lag.csv
for i in $(seq 1 20); do
  psqlp -d postgres -F, -c "\"select to_char(now(),'HH24:MI:SS'), coalesce(write_lag::text,'0'), coalesce(flush_lag::text,'0'), coalesce(replay_lag::text,'0'), pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) from pg_stat_replication\"" >> ${OUT}_lag.csv
  sleep 0.5
done
LAGMAX=$(python3 -I -c '
import csv,sys
def ms(v):
    if v in ("0",""): return 0.0
    h,m,s=v.split(":"); return (int(h)*3600+int(m)*60+float(s))*1000
r=list(csv.DictReader(open(sys.argv[1])))
print("%.2f %.2f %d" % (max(ms(x["replay_lag"]) for x in r), sum(ms(x["replay_lag"]) for x in r)/len(r), max(int(float(x["lag_bytes"])) for x in r)))' ${OUT}_lag.csv)
read -r LAG_MAX_MS LAG_AVG_MS LAG_MAX_BYTES <<< "$LAGMAX"
log "replay lag over 10 s: max ${LAG_MAX_MS} ms, avg ${LAG_AVG_MS} ms, max ${LAG_MAX_BYTES} bytes behind"
log "2) crash the primary (docker kill pca-db)"
T0=$(now_ms); app "sudo docker kill pca-db >/dev/null"
sleep 1; kill $W 2>/dev/null || true; wait $W 2>/dev/null || true
ACK_LAST=$(grep -E '^[0-9]+\|' ${OUT}_writer_acks.txt | tail -1)
ACK_ID=${ACK_LAST%%|*}; ACK_TS=${ACK_LAST##*|}
REP_LAST=$(psqlr -d rpo_test -c "\"select id, extract(epoch from ts)*1000 from t order by id desc limit 1\"")
REP_ID=${REP_LAST%%|*}
LOST=$(( ACK_ID - REP_ID )); [ $LOST -lt 0 ] && LOST=0
RPO_MS=$(python3 -I -c "print(max(0, round(float('$ACK_TS') - float('${REP_LAST##*|}'), 1)))")
log "last acknowledged write id=$ACK_ID, last row on replica id=$REP_ID -> lost $LOST committed rows (RPO = ${RPO_MS} ms of writes)"
log "3) manual promotion + DNS switch"
T1=$(now_ms)
psqlr -d postgres -c "\"select pg_promote(true, 30)\"" >/dev/null
until [ "$(psqlr -d postgres -c "\"select pg_is_in_recovery()\"")" = f ]; do sleep 0.2; done
T_PROM=$(( $(now_ms) - T1 ))
app "sudo docker network disconnect $NET pca-db-replica && sudo docker network connect --alias db $NET pca-db-replica"
T_SW=$(( $(now_ms) - T0 ))
psqlr -d rpo_test -c "\"insert into t default values\"" && WRITABLE=yes || WRITABLE=no
log "replica promoted in ${T_PROM} ms, writable=$WRITABLE, now answers as 'db' ($T_SW ms after the crash)"
# wait until the user probe is OK again
until tail -1 ${OUT}_probe.csv | grep -q ',1,$'; do sleep 0.2; (( $(now_ms) - T0 > 180000 )) && break; done
T_APP=$(( $(now_ms) - T0 ))
log "Odoo answering again through the LB $T_APP ms after the crash"
sleep 10; kill $P 2>/dev/null; wait $P 2>/dev/null || true
PS_JSON=$(python3 -I "$LAB/scenarios/probe_summary.py" ${OUT}_probe.csv)
GAP=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["max_gap_ms"])' "$PS_JSON")
PF=$(python3 -I -c 'import json,sys; p=json.loads(sys.argv[1]); print("%d/%d" % (p["failed"],p["total"]))' "$PS_JSON")
log "4) restore the original topology"
app "sudo docker rm -f pca-db-replica >/dev/null && sudo docker volume rm pca-odoo_pg-replica >/dev/null && sudo docker start pca-db >/dev/null"
for i in $(seq 1 60); do [ "$(container_healthy pca-db)" = healthy ] && break; sleep 1; done
app "cd /opt/pca-odoo && sudo docker compose restart odoo-1 odoo-2 odoo-3 >/dev/null 2>&1 && sudo docker compose up -d db-replica 2>&1 | tail -1" >/dev/null
for i in $(seq 1 120); do [ "$(container_healthy pca-db-replica)" = healthy ] && break; sleep 1; done
"$LAB/scenarios/reset_lab.sh" | tail -1
STATE2=$(psqlp -d postgres -c "\"select state from pg_stat_replication limit 1\"")
log "after restore: replica $STATE2"
PASS=PASS; [ "$WRITABLE" = yes ] && [ "$STATE2" = streaming ] || PASS=FAIL
python3 -I -c 'import json,sys; print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2])), indent=1))' scenario S6 ts "$TS" replay_lag_max_ms "$LAG_MAX_MS" replay_lag_avg_ms "$LAG_AVG_MS" lag_max_bytes "$LAG_MAX_BYTES" ack_last_id "$ACK_ID" replica_last_id "$REP_ID" lost_rows "$LOST" rpo_ms "$RPO_MS" promote_ms "$T_PROM" crash_to_db_switched_ms "$T_SW" crash_to_odoo_ok_ms "$T_APP" probe_failed "$PF" probe_max_gap_ms "$GAP" replica_after_restore "$STATE2" > ${OUT}_result.json
printf "S6\t%s\tdb-failover\treplay_lag_max_ms=%s\tlag_avg_ms=%s\tlost_rows=%s\trpo_ms=%s\tpromote_ms=%s\tcrash_to_db_ms=%s\tcrash_to_odoo_ok_ms=%s\tprobe_failed=%s\tafter_restore=%s\t%s\n" "$TS" "$LAG_MAX_MS" "$LAG_AVG_MS" "$LOST" "$RPO_MS" "$T_PROM" "$T_SW" "$T_APP" "$PF" "$STATE2" "$PASS" >> "$RAW/results.tsv"
echo "VERDICT S6 $PASS: replication lag max ${LAG_MAX_MS} ms (avg ${LAG_AVG_MS}); primary crash -> lost ${LOST} committed rows (RPO ${RPO_MS} ms); promotion ${T_PROM} ms; Odoo back ${T_APP} ms after crash (manual); probe failed ${PF}; replica after restore: ${STATE2}"
```

**`scenarios/run_all.sh`**

```bash
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
```

**`scenarios/demo_watch.sh`**

```bash
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
```

### 4.12 Monitoring (kali)

**`monitoring/up.sh`**

```bash
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
for i in $(seq 1 60); do curl -fs -o /dev/null http://127.0.0.1:3000/api/health && break; sleep 1; done
echo "Prometheus http://127.0.0.1:9090  Grafana http://127.0.0.1:3000 (anonymous viewer; admin password in .secrets)"
```

**`monitoring/prometheus.yml`**

```yaml
global:
  scrape_interval: 2s        # fine-grained for the demo (state changes happen within seconds)
  evaluation_interval: 5s
scrape_configs:
  - job_name: haproxy-lb01
    metrics_path: /metrics
    static_configs:
      - targets: ['192.168.100.20:8404']   # HAProxy built-in Prometheus exporter, port firewalled to kali only
        labels: { instance: lb01 }
```

**`monitoring/grafana/provisioning/datasources/prometheus.yml`**

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prom
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
```

**`monitoring/grafana/provisioning/dashboards/provider.yml`**

```yaml
apiVersion: 1
providers:
  - name: pca
    folder: PCA lab
    type: file
    options: { path: /var/lib/grafana/dashboards }
```

The dashboard `monitoring/grafana/dashboards/pca-haproxy.json` (9 panels, generated by a Python snippet during the session)
contains: a state timeline computed as `UP*1 + DRAIN*2 + MAINT*3` per server (0 = DOWN), req/s per node
(`haproxy_server_http_responses_total`), responses by class at the edge, denied requests, redispatch/retry increases, current
sessions, average response time, check duration, up/down transitions.

### 4.13 Other tools

**`tools/check_phase3.sh`**

```bash
#!/bin/bash
# Phase 3 checks. Run from kali: ./tools/check_phase3.sh
cd "$(dirname "$0")/.."; source ./.secrets
echo "### $(date -Is) health from lb01 (allowed)"
ssh -q lb01 'for p in 8069 8169 8269; do echo "GET http://192.168.100.10:$p/web/health -> $(curl -sS -m 5 -w " HTTP %{http_code}" http://192.168.100.10:$p/web/health)"; done'
echo "### health from kali (must be refused)"
for p in 8069 8169 8269 8072 8172 8272; do echo "kali -> 192.168.100.10:$p : $(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://192.168.100.10:$p/web/health 2>&1 | head -1)"; done
echo "### PostgreSQL not published: $(ssh -q app01 "sudo ss -tlnH | grep -c ':5432 '") listeners on :5432 on the host"
echo "### login as vendeur1 on each node (from lb01) + search_read sale.order"
ssh -q lb01 "PW='$VENDEUR1_PASSWORD' bash -s" <<'R'
for p in 8069 8169 8269; do
  j=$(mktemp)
  r=$(curl -sS -m 20 -c $j -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"params\":{\"db\":\"pca_demo\",\"login\":\"vendeur1\",\"password\":\"$PW\"}}" http://192.168.100.10:$p/web/session/authenticate)
  uid=$(echo "$r" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("result",{}).get("uid"), d.get("result",{}).get("name"))')
  n=$(curl -sS -m 20 -b $j -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","params":{"model":"sale.order","method":"search_count","args":[[]],"kwargs":{}}}' http://192.168.100.10:$p/web/dataset/call_kw | python3 -c 'import sys,json; print(json.load(sys.stdin).get("result"))')
  echo "port $p: authenticate -> uid/name = $uid ; sale.order count visible = $n"
  rm -f $j
done
R
echo "### session shared between nodes: login on odoo-1, reuse cookie on odoo-3"
ssh -q lb01 "PW='$VENDEUR1_PASSWORD' bash -s" <<'R'
j=$(mktemp)
curl -sS -m 20 -c $j -o /dev/null -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"params\":{\"db\":\"pca_demo\",\"login\":\"vendeur1\",\"password\":\"$PW\"}}" http://192.168.100.10:8069/web/session/authenticate
for p in 8169 8269; do echo "session from 8069 used on $p -> $(curl -sS -m 20 -b $j -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","params":{}}' http://192.168.100.10:$p/web/session/get_session_info | python3 -c 'import sys,json; r=json.load(sys.stdin).get("result",{}); print("uid", r.get("uid"), r.get("username"))')"; done
rm -f $j
R
echo "### containers"; ssh -q app01 "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'; sudo docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'; free -h | head -2"
```

**`tools/check_phase4.sh`**

```bash
#!/bin/bash
# Phase 4 checks from kali. ./tools/check_phase4.sh
cd "$(dirname "$0")/.."; source ./.secrets
U=https://odoo.pca.lab
echo "### $(date -Is)"
echo "### 1. health through the LB with the system trust store (no -k)"
curl -sS -w '  -> HTTP %{http_code}, TLS verify result=%{ssl_verify_result}, %{http_version}\n' $U/web/health
echo "### 2. certificate presented"
echo | openssl s_client -connect odoo.pca.lab:443 -servername odoo.pca.lab 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName | tr '\n' ' '; echo
echo "    TLS 1.1 refused: $(echo | openssl s_client -connect odoo.pca.lab:443 -tls1_1 2>&1 | grep -qiE 'alert|no protocols|wrong version|unsupported' && echo yes || echo NO)"
echo "### 3. HTTP -> HTTPS redirect"
curl -sS -o /dev/null -w '  http://odoo.pca.lab/ -> %{http_code} Location: %{redirect_url}\n' http://odoo.pca.lab/
echo "### 4. security headers on /web/login"
curl -sS -o /dev/null -D - $U/web/login | grep -iE '^(strict-transport|x-content-type|x-frame|referrer-policy|set-cookie: SRV|server:)' | sed 's/^/  /'
echo "### 5. round robin: 30 requests without cookie -> server cookie assigned"
for i in $(seq 1 30); do curl -sS -o /dev/null -D - $U/web/login | grep -oiE 'SRV=odoo[0-9]'; done | sort | uniq -c | sed 's/^/  /'
echo "### 6. persistence: same cookie -> same server (10 requests with SRV=odoo2)"
for i in $(seq 1 10); do curl -sS -o /dev/null -b 'SRV=odoo2' -w '%{http_code} ' $U/web/health; done; echo
echo "### 7. form login through the public URL (as a browser does: GET /web/login, csrf, POST)"
J=$(mktemp); P=$(mktemp)
curl -sS -c $J -b $J $U/web/login -o $P
CSRF=$(grep -oP 'name="csrf_token" value="\K[^"]+' $P)
curl -sS -c $J -b $J -o /dev/null -w '  POST /web/login -> %{http_code} redirect=%{redirect_url}\n' --data-urlencode "csrf_token=$CSRF" --data-urlencode "login=vendeur1" --data-urlencode "password=$VENDEUR1_PASSWORD" --data-urlencode "redirect=" $U/web/login
curl -sS -b $J -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","params":{}}' $U/web/session/get_session_info | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print("  session_info: uid=%s login=%s db=%s" % (r["uid"], r["username"], r["db"]))'
curl -sS -b $J -o /dev/null -w '  GET /web#action=sale.action_orders (web client) -> %{http_code}\n' "$U/web#action=sale.action_orders"
echo "  server cookie for this browser session: $(grep -oE 'SRV\s+odoo[0-9]' $J | awk '{print $2}')"
echo "### 8. websocket upgrade on /websocket (be_odoo_ws, gevent port)"
curl -sS -m 5 -o /dev/null -b $J --http1.1 -w '  -> HTTP %{http_code}\n' -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" -H "Origin: $U" "$U/websocket" 2>&1 | grep -v 'timed out'
rm -f $J $P
echo "### 9. database manager blocked at the edge"
curl -sS -o /dev/null -w '  /web/database/manager -> %{http_code}\n' $U/web/database/manager
echo "### 10. stats page (kali only, auth)"
curl -sS -o /dev/null -w '  no auth  -> %{http_code}\n' http://lb01:8404/stats
curl -sS -o /dev/null -w '  with auth -> %{http_code}\n' -u "$HAPROXY_STATS_USER:$HAPROXY_STATS_PASSWORD" http://lb01:8404/stats
echo "### 11. boundaries"
echo "  app01 -> lb01:8404 (not kali): $(ssh -q app01 'curl -sS -m 4 -o /dev/null -w %{http_code} http://192.168.100.20:8404/stats 2>&1 | tail -c 60' </dev/null)"
echo "  app01 -> lb01:443 (lab subnet allowed): $(ssh -q app01 'curl -sS -m 4 -k -o /dev/null -w %{http_code} https://192.168.100.20/web/health 2>&1' </dev/null)"
echo "  kali NAT -> lb01 NAT IP 443: $(curl -sS -m 4 -k --interface 192.168.13.137 -o /dev/null -w %{http_code} https://192.168.13.138/web/health 2>&1 | tail -c 70)"
echo "### 12. HAProxy server state (runtime API)"
ssh -q lb01 'echo "show stat" | sudo socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18,37,8 | grep -E "odoo[123]|BACKEND" | column -ts,' </dev/null | sed 's/^/  /'
```

---

## 5. Results

Full tables with every run: `RESULTS.md`; raw data: `results/raw/` (180 files) and `results/raw/results.tsv`.

| Benefit / objective | Measured | Command | What it proves for the SMCA |
|---------------------|----------|---------|-----------------------------|
| Availability — detection | 2.80 / 2.86 s (stop), 4.49 s (kill) after the node stops serving; ≈ 6.1–6.2 s after the command | `./scenarios/s1_node_failure.sh`, `MODE=kill ./scenarios/s1_node_failure.sh` | automatic detection without a human: the incident clock starts and ends without intervention |
| Availability — user errors on crash | 0 % probe, 0 k6 (3 kill runs) | `MODE=kill …s1_node_failure.sh` | **application-tier RTO ≈ replay latency**, well under the 30 s objective |
| Availability — user errors on graceful stop | 0.21 % (1 of ~475 probe requests), 0 k6 | `…s1_node_failure.sh` | within ≤ 1 %; planned stops must use drain (S2) |
| Availability — longest user gap | 1.25–1.40 s | S1 | user-perceived RTO |
| Availability — session continuity | 0 session loss; odoo1 → odoo3 without re-login | S1 | no data/work loss for the user at node loss |
| Recovery — node back in rotation | 7.9–8.2 s after `docker start` | S1 | restoration time of the redundancy (N+1 back) |
| Maintenance without downtime | 0 failed (k6 3 437 + 4 017 + 3 772, probe 571 + 833 + 627) | `./scenarios/s2_rolling_update.sh` (3 runs incl. dry run) | change without interruption: planned downtime = 0 |
| Scalability (shared 2 vCPU) | successful req/s ×0.85, ×0.91, ×0.82; app01 CPU 91–94 % | `./scenarios/s3_scaleout.sh` | honest: no capacity gain on one host; capacity continuity needs independent nodes |
| Scalability (0.66 vCPU/node) | 1 node 93–95 % errors; 3 nodes 0 errors, ×1.74–×2.5 successful req/s | `CPU_PER_NODE=0.66 ./scenarios/s3_scaleout.sh` | N+1 sizing keeps the critical service available under load |
| Edge security | 500 / 425 × 429 of 600; 100 / 175 reach Odoo; exempt 300 × 200; guessed header 150 × 429; login 200/303/200 after | `./scenarios/s4_rate_limit.sh` | availability protected against abusive clients |
| Observability (hang) | DOWN in 12.66 / 10.33 s, UP 4.38 / 3.76 s after unpause, 4 log transitions | `./scenarios/s5_lb_visibility.sh` | monitoring and measurement (§9.1) — the evidence behind every RTO number |
| DB replication lag | avg 0.92 / 1.33 ms, max 3.69 / 5.65 ms | `./scenarios/s6_db_failover.sh` | **RPO** in normal operation ≈ milliseconds |
| DB rows lost at primary crash | 0 / 0 | S6 | RPO = 0 observed (async: not guaranteed) |
| DB promotion / Odoo back | 2.81 / 1.54 s; 6.87 / 5.39 s after crash | S6 | DB-tier RTO with a scripted manual runbook (a human adds decision time) |
| Functional | 10/10/10 RR split; websocket 101; TLS 1.1 refused; `/web/database` 403; direct backend refused | `./tools/check_phase3.sh`, `./tools/check_phase4.sh` | correctness of the platform and of the edge controls |

---

## 6. How to rebuild the lab from scratch on fresh VMs

Assumptions: three VMs on a host-only network 192.168.100.0/24 (+ NAT for internet): app01 (RHEL 9, ≥ 2 vCPU, ≥ 4.5 GiB RAM,
≥ 15 GB free), lb01 (RHEL 9, ≥ 1 GiB), kali. SSH key access from kali with aliases `app01`/`lb01` and passwordless sudo
already set up by a human (as in this lab). The repository `~/pca-lab` is on kali with a `.secrets` file.

1. **Secrets** (kali): create `~/pca-lab/.secrets` (mode 600) with the 12 keys listed in phase 0 (+ `GRAFANA_ADMIN_PASSWORD`),
   values from `openssl rand -base64 33 | tr -dc 'A-Za-z0-9' | head -c 24`.
2. **Inventory**: `for h in app01 lb01; do ssh -q $h 'bash -s' < tools/inventory.sh; done`.
3. **Names**: `for h in app01 lb01; do scp tools/set_hosts.sh $h:/tmp/ && ssh -q $h "sudo bash /tmp/set_hosts.sh && sudo hostnamectl set-hostname $h"; done; sudo bash tools/set_hosts.sh with-vip`.
4. **Base services**: `for h in app01 lb01; do ssh -q $h 'sudo systemctl disable --now cups cups.socket cups.path avahi-daemon.socket avahi-daemon cockpit.socket; sudo systemctl set-default multi-user.target'; done`.
5. **sshd**: `for h in app01 lb01; do scp common/01-pca-hardening.conf tools/harden_sshd.sh $h:/tmp/ && ssh -q $h 'sudo bash /tmp/harden_sshd.sh'; done` (key login must work first).
6. **firewalld**: as in phase 2 (`apply` then `commit` from a new SSH session).
7. **Updates**: `ssh -q app01 'sudo dnf -y update --security && sudo dnf needs-restarting -r || sudo systemctl reboot'` (same on lb01 once it has repository access).
8. **Docker on app01** (if absent) [not verified — Docker CE was already installed in this lab]: Docker CE repo + `dnf install docker-ce docker-ce-cli containerd.io docker-compose-plugin`, `systemctl enable --now docker`.
9. **Docker SELinux**: `scp app01/daemon.json app01:/tmp/ && ssh -q app01 'sudo install -m 644 /tmp/daemon.json /etc/docker/daemon.json && sudo systemctl restart docker'`.
10. **Odoo stack**: `./app01/deploy.sh` (first run prints "database not initialised") → `./app01/init_db.sh` → `./app01/deploy.sh` (waits for 4 healthy containers; the replica starts too).
11. **DOCKER-USER**: `ssh -q app01 'sudo install -m 644 /opt/pca-odoo/scripts/pca-docker-user.service /etc/systemd/system/ && sudo restorecon /etc/systemd/system/pca-docker-user.service && sudo systemctl daemon-reload && sudo systemctl enable --now pca-docker-user'`.
12. **Check**: `./tools/check_phase3.sh` (200 from lb01, refused from kali, login on each node, shared session).
13. **HAProxy**: `scp lb01/install_haproxy.sh lb01:/tmp/ && ssh -q lb01 'sudo bash /tmp/install_haproxy.sh'` (needs the RHEL DVD in the VM's drive; with repository access a plain `dnf install haproxy socat` is equivalent).
14. **PKI**: `./pki/make_pki.sh && sudo install -m 644 pki/ca.crt /usr/local/share/ca-certificates/pca-lab-ca.crt && sudo update-ca-certificates`; Firefox policy and Chromium NSS as in phase 4.
15. **LB config**: `./lb01/deploy.sh` → `./tools/check_phase4.sh`.
16. **Test tools** (kali): k6 from the GitHub release with checksum verification (phase 5); Python 3 standard library only for the probe.
17. **Scenarios**: `./scenarios/reset_lab.sh`, then `./scenarios/run_all.sh` and `./scenarios/s6_db_failover.sh`.
18. **Monitoring**: `./monitoring/up.sh` → http://127.0.0.1:3000.

---

## 7. How to operate it

**Start-up order.** app01 first (PostgreSQL, then the replica and the Odoo nodes start automatically, `restart: unless-stopped`;
~1 min to all healthy), then lb01 (HAProxy enabled at boot), then kali. Do not suspend the host while the lab runs (on resume
Odoo kills its workers for `limit_time_real` and the first requests fail).

**Health checks.**
```bash
cd ~/pca-lab
ssh -q app01 true && ssh -q lb01 true && echo SSH-OK
./scenarios/reset_lab.sh                      # "RESET OK: 4 containers healthy, 6/6 HAProxy servers UP, stick-table cleared"
curl -sS https://odoo.pca.lab/web/health      # {"status": "pass"}
ssh -q lb01 'echo "show stat" | sudo socat stdio /run/haproxy/admin.sock' | cut -d, -f1,2,5,8,17,18,37 | column -ts,
ssh -q app01 'sudo docker ps --format "{{.Names}} {{.Status}}"; sudo docker exec pca-db psql -U odoo -d postgres -tAc "select state from pg_stat_replication"'
podman ps; ./monitoring/up.sh                 # if Prometheus/Grafana are not running
```

**Running the demos.** `./scenarios/s1_node_failure.sh` (`MODE=kill`), `s2_rolling_update.sh`, `s3_scaleout.sh`
(`CPU_PER_NODE=0.66`), `s4_rate_limit.sh`, `s5_lb_visibility.sh`, `s6_db_failover.sh`, `run_all.sh`; live view
`./scenarios/demo_watch.sh [seconds] [node]`; the full live sequence is `DEMO-CHECKLIST.md`.

**Runtime operations.**
```bash
hap(){ ssh -q lb01 "echo '$*' | sudo socat stdio /run/haproxy/admin.sock"; }
hap set server be_odoo/odoo2 state drain   # then maint / ready (also for be_odoo_ws)
hap clear table fe_https                   # unblock a client after a 429 test
ssh -q lb01 'sudo journalctl -u haproxy -f -n0 -o cat' | grep --line-buffered -v WARNING | awk '$6==429 || $6 ~ /^5[0-9][0-9]$/ || /^Server be_/ {print; fflush()}'
```

**Resetting.** `./scenarios/reset_lab.sh` (compose up, wait healthy, all servers ready/UP, warm-up, clear table and counters).

**Shutting down cleanly.**
```bash
./monitoring/down.sh                                               # kali (optional)
ssh -q lb01 'sudo systemctl stop haproxy'                          # optional, stops accepting users first
ssh -q app01 'cd /opt/pca-odoo && sudo docker compose stop'        # Odoo nodes, replica, then primary (compose ordering)
ssh -q app01 'sudo systemctl poweroff'; ssh -q lb01 'sudo systemctl poweroff'
```
`docker compose stop` keeps containers and volumes; `docker compose up -d` (or a VM boot) brings them back. [not verified:
a full power-off/power-on cycle of the VMs was not performed during the session; app01 was rebooted once, before the stack existed.]

---

## 8. Known limits and residual risks

| Limit / risk | Evidence | Production treatment |
|--------------|----------|----------------------|
| lb01 is a single load balancer | architecture | keepalived/VRRP pair with a floating VIP |
| app01 is a single VM for all Odoo nodes; no real capacity gain from scale-out | S3 shared ×0.82–0.91 | nodes on ≥ 2 hosts; shared filestore (NFS/Ceph/S3) |
| PostgreSQL failover is manual (scripted runbook); async replica → RPO 0 only observed at ~9 commits/s | S6 | Patroni + etcd (fencing, automatic election), synchronous replication if RPO must be 0, pgBackRest backups |
| S6 restore discards Odoo writes made during the failover window | `s6_db_failover.sh` header | real switchover procedure (pg_rewind or rebuild of the old primary as standby) |
| Graceful stop without drain loses ~1 in-flight request | S1 stop 0.21 % | always drain first (S2); newer HAProxy L7-retry handling |
| L7 retry may replay a POST whose reply was lost | config choice | accepted (tiny window: Odoo commits at the end); idempotency keys for critical writes |
| `/web/health` does not test the DB | Odoo code | deeper check with care, separate DB alerting |
| Hang detection is slower than crash detection (10–13 s vs 3–4.5 s) | S5 vs S1 | tune `timeout check`, `observe layer7` + `error-limit` [not tested] |
| Cold nodes are slow for ~10–15 s after a start | phase 5 problem 12 | warm-up + `slowstart 15s` (applied) |
| lb01 not patched | BLOCKERS B1 | restore subscription, patch through a rolling LB procedure |
| TLS ends at the LB; LB → backends in clear | design | re-encrypt or dedicated network |
| Rate limit keyed on source IP | design | per-session/login tracking, upstream WAF/anti-DDoS |
| Lab host performance varies (suspend, slower after resume) | S3 INVALID runs, smoke p95 62 → 115 ms | dedicated hosts for capacity tests |
| Three anonymous Docker volumes exist on app01 (`224afe5b…`, `62000de3…`, `ca2bf13c…`) | `docker volume ls` | origin [not verified] — probably the `odoo:17` image's declared volumes from one-off `compose run` containers; safe to inspect and prune |
| `client.keys.rpmsave` (Wazuh agent key) deleted with `rm`, not `shred` | phase 1 | — (the agent and its manager no longer exist) |

---

## 9. File map of the repository

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | the assignment and rules (written by the human) |
| `README.md` | architecture, IP plan, deployment, scenarios, reset |
| `RESULTS.md` | every measured number per scenario and run, with commands |
| `SMCA-MAPPING.md` | benefit → continuity objective → evidence; residual risks |
| `DEFENSE-NOTES.md` | 15 (+3) jury questions and answers (French) |
| `DEMO-CHECKLIST.md` | live demo sequence for 20/11 (French), dry-run fixes included |
| `PRESENTATION-27-11.md` | 5-minute talk outline (French) |
| `DECISIONS.md` | every decision with its reason, by phase |
| `BLOCKERS.md` | B1: lb01 Red Hat content access |
| `BUILD-LOG.md` | this file (complete technical record) |
| `.gitignore` | excludes `.secrets`, keys, PEM bundles, S4 temporary files |
| `.secrets` | (not in git) all secrets |
| `app01/docker-compose.yml` | Odoo ×3 + PostgreSQL + replica |
| `app01/config/odoo.conf.tpl` | Odoo config template |
| `app01/daemon.json` | Docker daemon: SELinux, no-new-privileges, journald |
| `app01/deploy.sh` | render + copy + replication setup + compose up + wait healthy |
| `app01/init_db.sh` | create `pca_demo`, users, base URL, signup policy |
| `app01/scripts/pca-docker-user.sh`, `.service` | DOCKER-USER filtering + its systemd unit |
| `app01/scripts/replica-entrypoint.sh` | replica bootstrap (pg_basebackup) |
| `app01/scripts/setup-replication.sql.tpl` | replication role + slot (template) |
| `lb01/haproxy.cfg.tpl` | HAProxy config template |
| `lb01/deploy.sh` | render, validate, install, reload HAProxy |
| `lb01/install_haproxy.sh` | install haproxy + socat from the RHEL DVD |
| `lb01/pca-haproxy.tmpfiles.conf` | creates `/run/haproxy` |
| `common/01-pca-hardening.conf` | sshd drop-in |
| `pki/make_pki.sh`, `ca.crt`, `odoo.pca.lab.crt`, `server.ext`, `ca.srl` | local PKI (keys and PEM bundle git-ignored) |
| `tools/inventory.sh` | read-only host inventory |
| `tools/set_hosts.sh` | managed `/etc/hosts` block |
| `tools/harden_sshd.sh` | sshd hardening with `sshd -t` guard |
| `tools/firewall.sh` | firewalld policy with rollback timer |
| `tools/verify_phase1.sh`, `verify_phase2.sh` | phase verifications |
| `tools/check_phase3.sh`, `check_phase4.sh` | functional checks |
| `scenarios/lib.sh` | shared helpers (runtime API, waits, k6 wrapper, warm-up) |
| `scenarios/probe.py`, `probe_summary.py` | user probe and its summary |
| `scenarios/k6/odoo_load.js` | k6 sales-user load |
| `scenarios/k6/browser_session.js` | real Chromium session (rate-limit sizing) |
| `scenarios/reset_lab.sh` | back to a known state |
| `scenarios/s1_node_failure.sh` … `s6_db_failover.sh` | the six scenarios |
| `scenarios/run_all.sh` | S1–S5 campaign |
| `scenarios/demo_watch.sh` | coloured live view for the demo |
| `monitoring/up.sh`, `down.sh`, `prometheus.yml`, `grafana/…` | Prometheus + Grafana on kali |
| `results/raw/` | 180 raw result files (CSV, JSON, logs, stats) + `results.tsv` |
| `evidence/phase0…phase6/` | proofs per phase (inventories, verifications, checks, screenshots) |
| `evidence/dry-run/` | demo dry-run outputs and findings |
| `presentation/deck/`, `presentation/README.md` | slide deck source (8 slides) and its link |

Backups of overwritten originals on the VMs: `/root/pca-backup/` — app01: `99-wazuh.conf`, `firewalld-public.xml`,
`hosts.orig`, `sshd_config.d/`, seven `pca-odoo-<date>.tgz`; lb01: `60-logsentinel-victim.conf`, `firewalld-public.xml`,
`haproxy.cfg.orig`, `haproxy.cfg.prev`, `hosts.orig`, `ossec.conf`, `sshd_config.d/`, `wazuh.repo`.
