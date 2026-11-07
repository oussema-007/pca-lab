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
