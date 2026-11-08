# Results — measured numbers per scenario

All runs are from kali against `https://odoo.pca.lab` (lb01, HAProxy 2.4.22) → 3 × Odoo 17 on app01 (2 vCPU, 4.8 GiB).
Every run appends one line to [`results/raw/results.tsv`](results/raw/results.tsv); raw files (probe CSV, k6 JSON, HAProxy logs,
stats snapshots) are in `results/raw/<scenario>_<timestamp>_*`. Each scenario starts with `./scenarios/reset_lab.sh`.

Measurement tools: **probe** = one authenticated JSON-RPC call every 200 ms through the LB, persistent connection like a browser,
no client-side retry (`scenarios/probe.py`); **k6** = 4–12 virtual sales users (login once, then `search_read` on sale.order /
res.partner / product.product + web client page) with the rate-limit exemption header; **runtime API** polled every ~0.25–0.5 s
for HAProxy states. Clocks: chrony (VMs) / timesyncd (kali), offsets < 1 ms.

> Environment note: the hypervisor host was suspended for ~2 h 45 during one S3 run (marked INVALID, kept for transparency).
> After the resume the host is ~2× slower (same k6 smoke profile: p95 62 ms before, 115 ms after), which is why absolute
> latencies differ between the 2026-11-07 and 2026-11-08 runs. Comparisons are always made within one run.

## Summary table

| Benefit | Metric | Measured (final config) | Target | Status |
|---------|--------|-------------------------|--------|--------|
| Availability (S1) | LB detection after the node stops serving | **2.8–4.5 s** (≈ 6.1–6.2 s after the `docker` command) | ≤ ~8 s | PASS |
| Availability (S1) | user-visible failed requests, crash (SIGKILL) | **0 %** probe, **0** k6 (3 runs) | ≤ 1 %, target 0 | PASS |
| Availability (S1) | user-visible failed requests, graceful stop | **0.21 %** probe (1 of ~475), **0** k6 | ≤ 1 % | PASS |
| Availability (S1) | session kept across node change | yes, 0 session loss in every run (odoo1 → odoo3, no re-login) | yes | PASS |
| Availability (S1) | longest gap for the user (≈ user-perceived RTO) | **1.25–1.40 s** | ≤ 30 s | PASS |
| Availability (S1) | node back in rotation after restart | **7.9–8.2 s** | — | — |
| Hung node (S5) | detection of a frozen node (`docker pause`) | **10.3–12.7 s** | — | PASS |
| Maintenance (S2) | failed requests during rolling replacement of 3 nodes | **0** (k6 3 437 + 4 017 req, probe 571 + 833 req) | 0 | PASS |
| Scalability (S3) | successful req/s, 1 → 3 nodes, shared 2 vCPU | 106 → 90 (×0.85), 44 → 40 (×0.91), 53 → 44 (×0.82) — CPU-bound at 1 node (91–93 %) | report honestly | DONE |
| Scalability (S3) | independent nodes (0.66 vCPU each) | 1 node: **93–95 % errors** (overload → health checks time out → 503); 3 nodes: **0 errors**, ×1.74 successful req/s | report | DONE |
| Edge security (S4) | burst of 600 req without exemption | **500 / 425 × 429**, only **100 / 175** reach Odoo | 429 above threshold | PASS |
| Edge security (S4) | exempt load-test client / normal browsing after burst | 300 × 200, 0 × 429 / login 200 → 303 → 200 | not throttled / works | PASS |
| Observability (S5) | state change visible in stats, logs, metrics | yes: UP → UP 2/3 → UP 1/3 → DOWN → DOWN 1/2 → UP, 4 log transitions, Prometheus | yes | PASS |
| DB tier (S6) | replication lag (RPO in normal operation) | avg **0.9–1.3 ms**, max 3.7–5.7 ms, 0 bytes behind | ≤ 1 s | PASS |
| DB tier (S6) | committed rows lost when the primary crashes | **0** (RPO = 0 in both runs, async replica) | ≤ 1 s | PASS |
| DB tier (S6) | promotion / Odoo back after primary crash (scripted manual runbook) | promotion **1.5–2.8 s**, Odoo answering **5.4–6.9 s** after the crash (21–27 failed probe requests during the gap) | ≤ 5 min | PASS |

## S1 — node failure (`scenarios/s1_node_failure.sh`)

Command: `./scenarios/s1_node_failure.sh` (graceful `docker stop odoo-1`) and `MODE=kill ./scenarios/s1_node_failure.sh` (SIGKILL).
Probe pinned to odoo1 + k6 5 VUs; odoo-1 down 25 s, then restarted.

| Run | Mode | Node stopped serving (after cmd) | LB detection after that | From cmd | Probe failed | Probe max gap | k6 failed | Session lost | Back in LB | Verdict |
|-----|------|------|------|------|------|------|------|------|------|------|
| 20261108-012304 | stop | 3.42 s | **2.80 s** | 6.20 s | 0.212 % (1) | 1.35 s | 0 / ~2 800 | 0 | 8.1 s | PASS |
| 20261108-012500 | stop | 3.32 s | **2.86 s** | 6.17 s | 0.211 % (1) | 1.40 s | 0 | 0 | 8.2 s | PASS |
| 20261108-012657 | kill | 1.66 s¹ | **4.49 s** | 6.14 s | **0 %** | 1.25 s | 0 | 0 | 7.9 s | PASS |

Earlier runs (same scenario, before the metric/config was final — kept for transparency):

| Run | Mode | Detection from cmd | Probe failed | Max gap | k6 failed | Note |
|-----|------|------|------|------|------|------|
| 20261107-213430 | stop | 6.10 s | 0.211 % | 1.98 s | 0 | before `redispatch 1` / L7 retry (2 s gap = retry pauses on the dead server) |
| 20261107-213701 | stop | 6.14 s | 0.211 % | 1.04 s | 0 | `redispatch 1` + `retry-on`, without request buffering |
| 20261107-213942 | stop | 6.91 s | 0.211 % | 1.12 s | 0 | + `http-buffer-request` |
| 20261107-214132 | kill | 6.05 s | **0 %** | 1.15 s | 0 | final failover config |
| 20261107-214354 | stop | 5.50 s | 0.211 % | 1.03 s | 0 | keep-alive probe |
| 20261108-005706 | stop | 10.22 s | 0.211 % | 2.84 s | 0 | **FAIL** under the old metric: detection was measured from the command, which includes Odoo's graceful shutdown (node still serving). Metric fixed to "after the container exit" |
| 20261108-005903 | kill | 7.51 s | 0 % | 1.26 s | 0 | probe already moved to odoo3 before the kill (cold odoo1 flapped → warm-up + `slowstart` added) |

¹ includes ~1.5 s of ssh + docker CLI latency between kali's T0 and the actual kill.

Reading: HAProxy needs 3 failed checks at 2 s intervals; the user does not wait for it because failed requests are retried and
redispatched (`wredis`/`wretr` counters in `*_result.json`, Grafana panel "Retries and redispatches"). With a graceful stop, exactly
one in-flight request per run (HAProxy termination state `SH`, server closed after accepting) is not replayed by HAProxy 2.4.22.

## S2 — rolling update (`scenarios/s2_rolling_update.sh`)

Command: `./scenarios/s2_rolling_update.sh` — under k6 5 VUs + probe, for each node: `drain` → 0 sessions → `maint` →
`docker compose up -d --force-recreate odoo-N` → healthy (→ warm-up) → `ready` → UP.

| Run | Window | k6 requests | k6 failed | RPC errors | Probe failed | Probe max gap | k6 p95 | Verdict |
|-----|--------|------|------|------|------|------|------|------|
| 20261107-214752 | 92 s | 3 437 | **0** | 0 | **0 / 571** | 1.14 s | 62 ms | PASS |
| 20261108-010106 | 155 s | 4 017 | **0** | 0 | **0 / 833** | 1.38 s | 187 ms | PASS |

Per-node steps (run 1, `results/raw/s2_20261107-214752_steps.tsv`): drain→idle 1.5–14.4 s, recreate→healthy 6.1–7.1 s,
ready→UP 0.3–2.4 s; each container ID changed (old → new), proving a real replacement.

## S3 — scale-out (`scenarios/s3_scaleout.sh`)

Commands: `./scenarios/s3_scaleout.sh` (shared CPU) and `CPU_PER_NODE=0.66 ./scenarios/s3_scaleout.sh` (each Odoo container capped
with `docker update`, reverted afterwards). Profile: 12 VUs, no think time, 60 s, after a 15 s warm-up; 1 node = odoo2/odoo3 in `maint`.
`nproc` on app01 = 2. Successful req/s = (requests − failed) / duration.

| Run | Variant | 1 node ok req/s | p95 | err | app01 CPU | 3 nodes ok req/s | p95 | err | CPU | Gain |
|-----|---------|------|------|------|------|------|------|------|------|------|
| 20261107-215004 | shared | 106.3 | 143 ms | 0 | 93.1 % | 90.0 | 183 ms | 0 | 94.5 % | ×0.85 |
| 20261108-004151 | shared | 44.2 | 381 ms | 0 | 91.1 % | 40.3 | 416 ms | 0 | 93.9 % | ×0.91 |
| 20261108-010421 | shared | 52.9 | 283 ms | 0 | 91.6 % | 43.6 | 396 ms | 0 | 94.1 % | ×0.82 |
| 20261108-004509 | capped 0.66 | 15.8² | 282 ms | **94.6 %** | 35.6 % | 40.0 | 414 ms | 0 | 93.7 % | ×2.5 |
| 20261108-010741 | capped 0.66 | 15.7 | 363 ms | **93.0 %** | 36.3 % | 27.3 | 599 ms | 0 | 91.7 % | ×1.74 |
| 20261107-215343 / 20261108-003743 | both | — | — | — | — | — | — | — | — | INVALID (host suspended) |

² computed from the k6 JSON (995 successful requests in 63 s); this run predates the `ok_rps` column.

Interpretation (honest): with the 3 nodes on the same 2-vCPU VM, one node already saturates the CPU (91–93 %), so adding
containers adds contention, not capacity (×0.82–0.91). kali (load generator) stayed at 25–45 % CPU, so it was not the bottleneck.
With independent nodes of fixed size (emulated), a single node is overloaded: its health checks time out (`Layer7 timeout`),
HAProxy has no server left and answers 503 to ~94 % of requests; three nodes serve the same load with 0 errors.
Per-server split with 3 nodes is even (e.g. 832 / 852 / 840 requests).

## S4 — rate limiting (`scenarios/s4_rate_limit.sh`)

Command: `./scenarios/s4_rate_limit.sh` — 600 × `GET /web/login`, 20 in parallel, no exemption header; limit **100 req / 10 s / IP**
(`sc_http_req_rate(0) gt 100`).

| Run | 200 | 429 | First 429 | Reached Odoo | Exempt client (300 req) | Wrong header value | After 11 s: login page / POST / web client | Verdict |
|-----|-----|-----|------|------|------|------|------|------|
| 20261108-005430 | 100 | **500** | #85 | 100 | 300 × 200 | (50 req, below limit) | 200 / 303 / 200 | PASS |
| 20261108-011104 | 175 | **425** | #175 | 175 | 300 × 200 | 150 req → throttled | 200 / 303 / 200 | PASS |

The 429s are produced by HAProxy itself (backend `stot` grew only by the 200s). Run 2 lasted longer (slower backend), so the
sliding 10 s window let ~100 requests through per window. A first attempt with a 200 req/10 s limit never triggered
(600 × 200): one client cannot exceed ~11 login pages/s on this backend → limit lowered to 100 after measuring a real browser
session = 33 requests (`scenarios/k6/browser_session.js`, screenshot `evidence/phase4/browser-sales-orders.png`).

## S5 — observability (`scenarios/s5_lb_visibility.sh`)

Command: `./scenarios/s5_lb_visibility.sh` — snapshot stats CSV/HTML/Prometheus, `docker pause odoo-3` (frozen process), unpause.

| Run | Detection (hang) | Back UP after unpause | Log transitions | State sequence (runtime API) | Verdict |
|-----|------|------|------|------|------|
| 20261108-005616 | 12.66 s | 4.38 s | 4 | UP → UP 2/3 (L7TOUT) → UP 1/3 → DOWN → DOWN 1/2 (L7OK) → UP | PASS |
| 20261108-011235 | 10.33 s | 3.76 s | 4 | same | PASS |

Files: `*_timeline.csv` (state every 0.5 s), `*_haproxy_transitions.log`, `*_stats_page.html`, `*_metrics_down.txt`.
Grafana (phase 6) shows the same transitions: `evidence/phase6/grafana-dashboard.png` (DRAIN blue, MAINT orange, DOWN red, redispatches).

## S6 — database replica, RPO and manual promotion (phase 6, `scenarios/s6_db_failover.sh`)

Command: `./scenarios/s6_db_failover.sh` — async streaming replica `pca-db-replica` (slot `replica1`); write load ~9 inserts/s
into a separate database `rpo_test`; `docker kill pca-db`; compare last acknowledged id with last replicated id; `pg_promote()`;
give the replica the Docker DNS alias `db`; wait for Odoo through the LB; restore (old primary back, replica rebuilt).

| Run | Replay lag avg / max | Rows lost at crash | RPO | Promotion | Crash → `db` switched | Crash → Odoo OK via LB | Probe failed | Replica after restore | Verdict |
|-----|------|------|------|------|------|------|------|------|------|
| 20261108-012942 | 0.92 / 3.69 ms | **0** (208 = 208) | 0 ms | 2.81 s | 5.95 s | **6.87 s** | 27 / 195 | streaming | PASS |
| 20261108-013143 | 1.33 / 5.65 ms | **0** | 0 ms | 1.54 s | 4.69 s | **5.39 s** | 21 / 185 | streaming | PASS |

Caveats: the promotion is executed by the runbook script (a human would add detection + decision time: minutes); RPO 0 here is
an observation at low write rate, asynchronous replication does not guarantee it (synchronous replication would).
During the DB outage Odoo fails (the LB cannot help: all nodes share the DB) — the 21–27 failed probe requests are that window.

## Phase 3/4 functional checks

| Check | Result | Evidence |
|-------|--------|----------|
| `/web/health` from lb01 on 8069/8169/8269 | 200 ×3 | `evidence/phase3/checks.txt` |
| same from kali (bypass attempt) | refused ×6 ports (after DOCKER-USER fix; before: 200, `docker-firewall-bypass-before.txt`) | `evidence/phase3/` |
| login vendeur1 on each node, session created on odoo-1 valid on odoo-2/3 | OK | `evidence/phase3/checks.txt` |
| HTTPS with trusted cert, TLS 1.1 refused, 301 from HTTP, HSTS + headers | OK | `evidence/phase4/checks.txt` |
| 30 new clients → SRV cookie split | **10 / 10 / 10** | `evidence/phase4/checks.txt` |
| form login through the public URL, websocket upgrade | 303 → session uid 8 / **101** | `evidence/phase4/checks.txt` |
| `/web/database/manager` | 403 at the edge | `evidence/phase4/checks.txt` |
| stats 401 without auth / 200 with; 8404 from app01 refused; NAT IP refused | OK | `evidence/phase4/checks.txt` |
| real browser (Chromium) login + Sales list | OK | `evidence/phase4/browser-*.png` |
