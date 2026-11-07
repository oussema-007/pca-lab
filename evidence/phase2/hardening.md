# Phase 2 - Baseline hardening of app01 and lb01

Proof: `verify.txt` (state after the app01 reboot), `app01-security-update.txt`. Scripts: `tools/harden_sshd.sh`,
`tools/firewall.sh`, `common/01-pca-hardening.conf`, `tools/verify_phase2.sh`.

| # | Step | Where | Why (jury version) |
|---|------|-------|--------------------|
| 1 | Removed the old LogSentinel stack: Wazuh containers/volumes, Wazuh agent, nginx, postfix, Groq AI agent and its API key file (shredded), old CA private keys, `backupsvc` victim account and its password-login exception | both | Every service you don't run can't be attacked; leftover secrets are a leak risk. Smaller attack surface = fewer incidents in the continuity scope |
| 2 | SELinux **Enforcing** (runtime + `/etc/selinux/config`) | both | Mandatory access control: a compromised Odoo/HAProxy process stays confined to its domain (`container_t`, `haproxy_t`). We adapt policy with booleans/labels (`:Z`, `haproxy_connect_any`) instead of disabling it |
| 3 | firewalld active, zone `public`, **no service open to everyone**; only source-filtered rich rules | both | Default deny (REJECT). Each flow is explicitly allowed from a named source |
| 3a | app01: SSH only from kali (192.168.100.30); Odoo ports 8069/8072/8169/8172/8269/8272 only from lb01 (192.168.100.20) | app01 | Users can't bypass the load balancer (and its TLS, rate limit, logs). Backend is reachable only from the LB |
| 3b | lb01: 80/443 from 192.168.100.0/24, stats 8404 and SSH only from kali | lb01 | The LB is the single, controlled entry point; admin interfaces only from the admin station |
| 3c | Firewall changes applied runtime-only with a 120 s auto-rollback timer, committed only after a new SSH session succeeds | both | Change management: a bad rule can't lock out the admin (rollback plan built in) |
| 4 | sshd: `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `MaxAuthTries 3`, `LoginGraceTime 30`, `X11Forwarding no`, `AllowTcpForwarding no`, `AllowAgentForwarding no`, `ClientAliveInterval 300` | both | Key-only admin access (key login verified first), no direct root, fewer brute-force tries, no tunnelling through the servers. File is `01-pca-hardening.conf` because sshd keeps the **first** value read and RHEL's `50-redhat.conf` sets `X11Forwarding yes` |
| 5 | `dnf update --security` (189 advisories incl. kernel, glibc, openssh, openssl) + reboot into 5.14.0-687.66.1 | app01 | Patch known vulnerabilities before going live. On lb01 impossible (no Red Hat content access, BLOCKERS B1) |
| 6 | chrony active and synchronised on both (offset < 1 ms) | both | Consistent timestamps across LB logs, Odoo logs and k6 results: needed to compute detection time / RTO correctly |
| 7 | Disabled cups, avahi-daemon (mDNS), cockpit.socket; boot target `multi-user.target` (GUI off on app01) | both | No printing/discovery/web-admin on servers; GUI off frees ~0.7 GB RAM for Odoo |
| 8 | Only sshd listens before deployment (`ss -tlnp` in verify.txt) | both | Clean baseline: every later open port is one we added on purpose |

Negative tests (in verify.txt): password login refused, root login refused, SSH from a non-allowed source (kali NAT IP) refused.
