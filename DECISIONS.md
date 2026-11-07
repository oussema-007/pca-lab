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
