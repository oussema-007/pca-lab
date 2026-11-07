# Decisions log

Format: date - decision - reason.

## Phase 0
- 2026-11-07 - Real OS on both VMs is **RHEL 9.8** (table said 9.5/9.6). Real values used everywhere.
- 2026-11-07 - app01 NAT interface is `ens224` (not documented). app01 RAM is 4.8 GiB, lb01 RAM is 1.0 GiB, all machines have 2 vCPU. The memory budget for the Odoo stack (~3 GiB) fits app01; lb01 only runs HAProxy (native package, no Docker) to stay inside 1 GiB.
- 2026-11-07 - Secrets generated with `openssl rand`, stored only in `~/pca-lab/.secrets` (600, git-ignored). The k6 rate-limit exemption is a secret header (`LOADTEST_HEADER_NAME` / `LOADTEST_HEADER_VALUE`).
- 2026-11-07 - lb01 cannot reach Red Hat CDN (403, consumer deleted). Rule 4 forbids registration. Instead of the Docker fallback I use the **RHEL 9.6 DVD already attached to lb01** as a local read-only dnf repo (`file:///mnt/rhel-dvd/{BaseOS,AppStream}`): HAProxy stays the signed Red Hat RPM managed by systemd, which is lighter than Docker on a 1 GiB VM and keeps SELinux policy (`haproxy_t`). Trade-off: no security errata on lb01 until the subscription is fixed (BLOCKERS B1).
