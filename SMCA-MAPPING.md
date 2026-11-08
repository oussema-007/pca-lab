# SMCA mapping — what the load balancer brings to business continuity (ISO 22301)

Scope: the Odoo ERP (sales) is treated as a **critical activity** of the company. The business impact analysis (BIA) gives it
continuity objectives; this lab shows which of them the load balancer helps meet, with measured evidence from
[`RESULTS.md`](RESULTS.md) (raw data in `results/raw/`).

Vocabulary: **RTO** (Recovery Time Objective) = maximum acceptable interruption; **RPO** (Recovery Point Objective) = maximum
acceptable data loss, measured in time; **MTPD** = maximum tolerable period of disruption; **availability** = share of time
the service answers correctly.

## Example objectives for the lab (what a BIA would fix)

| Objective | Target used here | Why |
|-----------|------------------|-----|
| RTO of the sales front-end after the loss of **one application node** | ≤ 30 s, no re-login | Sales reps keep working during a node incident |
| User-visible failed requests during a node incident | ≤ 1 % (target 0) | Measured by a real user probe + load test |
| Interruption during **planned maintenance** (patch, upgrade) | 0 | ISO 22301 §8.4 / change management: change without disruption |
| RPO of the database tier | ≤ 1 s with streaming replication | Async replica (phase 6) |
| RTO of the database tier (manual promotion) | ≤ 5 min | Runbook driven, no automatic failover in the lab |
| Edge protection | abusive client throttled without impacting other users | Availability is also threatened by overload and attacks |

## Benefit → continuity objective → evidence

| LB benefit | Mechanism (HAProxy) | Continuity objective supported | Evidence (RESULTS.md) |
|-----------|---------------------|--------------------------------|------------------------|
| **Availability** | active health checks (`/web/health`, `inter 2s fall 3 rise 2`), automatic removal of a dead node, `retries 3`, `option redispatch 1`, L7 retry on empty response, shared sessions | **RTO** of the application tier after a node loss; availability of a critical service; no data/session loss (sessions in the shared volume) | **S1**: detection by the LB in ~6–8 s after the node stops; crash (SIGKILL): **0 failed user requests**, 0 failed k6 requests; graceful stop: 1/475 probe requests (0.21 %); session kept, user moved to another node without re-login |
| **Maintenance without downtime** | runtime API `drain` → `maint` → `ready`, cookie persistence + redispatch, one node at a time | change management without interruption (ISO 22301 §8.4.4 / §8.5, ITIL change); **planned downtime = 0**, which also protects the yearly availability budget | **S2**: 3 containers recreated one after the other under load, **0 failed requests** (k6 and user probe) in both runs |
| **Scalability** | add/remove a `server` line or set `ready`/`maint` at runtime; round robin over N nodes; `maxconn` per node queues instead of overloading | capacity continuity: absorb peaks (month-end, campaigns) without degrading the critical service; resilience by **N+1** sizing | **S3**: on the shared 2-vCPU VM no throughput gain (CPU-bound, honest result); with independent nodes (emulated 0.66 vCPU each) **1 node collapses (503 storm) while 3 nodes serve the same load with 0 errors** |
| **Security at the edge** | TLS ≥ 1.2 termination, HSTS + security headers, rate limit 100 req/10 s/IP → 429, `/web/database` blocked, backends reachable only from the LB (firewalld + DOCKER-USER) | availability against overload / brute force / scraping; integrity and confidentiality of ERP data in transit; reduced attack surface (ISO 27001 controls that support continuity) | **S4**: burst of 600 → only 100 reach Odoo, 500 × 429 from HAProxy; exempt load test not throttled; normal login works right after; direct backend access refused (phase 3) |
| **Observability** | stats page, runtime API, enriched logs (server, timers, termination state, request ID), Prometheus metrics, Grafana | detection and **measurement** of incidents (ISO 22301 §9.1: monitoring, measurement, analysis); proof for exercises and tests (§8.5) | **S5**: hung node: state machine UP → UP 2/3 → UP 1/3 → DOWN → UP visible in stats, logs and metrics; detection ~12 s for a hang vs ~6 s for a crash |
| **Database continuity (phase 6)** | not the LB itself: streaming replica + manual promotion | **RPO** and RTO of the data tier | **S6**: replication lag in milliseconds, rows lost at primary crash, promotion time, Odoo back after DNS switch |

### What the numbers mean for RTO / availability
- **Detection time is not the user RTO.** While HAProxy is still detecting a dead node, failing requests are replayed on another
  node; users saw 0 errors on a crash. The application-tier RTO is therefore effectively **the replay latency (≈1 s worst case)**,
  far below the 30 s objective. Without the LB (users bound to one server) the RTO would be the time to restart the node
  (≈ 8–17 s for the container to be back and warm, measured) **plus** human detection, and every user of that node would lose their work in progress.
- **Planned maintenance counts for zero downtime.** With monthly patching of 3 nodes, a single-server setup would lose
  several minutes per month of availability; with drain/maint it is zero (S2), which keeps the availability budget
  for real incidents (99.9 % ≈ 43 min/month).

## Residual risks (honest) and how production would treat them

| Residual risk in the lab | Impact | Production treatment |
|--------------------------|--------|----------------------|
| **app01 is a single VM**: the 3 Odoo nodes share one host, one disk, one hypervisor | loss of app01 = total outage; also no real capacity gain from scale-out (S3) | nodes on ≥ 2 hosts / availability zones; anti-affinity; filestore on shared storage (NFS/CephFS/S3 via `ir_attachment` external storage) |
| **PostgreSQL has no automatic failover** | DB crash = outage until manual promotion (S6) and Odoo repointed; async replica may lose the last milliseconds of commits (RPO > 0) | **Patroni** + etcd (automatic leader election, fencing), connection via HAProxy/PgBouncer on the leader, synchronous replication if RPO must be 0; tested backups (pgBackRest) for logical errors |
| **lb01 is a single load balancer** | loss of lb01 = total outage, although the backends are fine | **keepalived (VRRP) pair** with a floating VIP (failover ≈ 1–3 s), identical configs deployed from git, or DNS/anycast in front of 2 LBs |
| Shared Docker volume for filestore/sessions on one host | volume corruption hits all nodes | replicated storage + backups of the filestore together with the DB (consistent RPO) |
| lb01 has no Red Hat updates (BLOCKERS B1) | unpatched edge component | restore the subscription, patch regularly, include LB patching in the S2-style rolling procedure (requires the keepalived pair) |
| TLS ends at the LB; LB → backend in clear on the lab network | sniffing on the internal segment | re-encrypt to backends (TLS on Odoo side / mTLS) or a dedicated encrypted network |
| Rate limit keyed on source IP | users behind one NAT share a quota; distributed attacks bypass it | track by session/login as well, WAF/anti-DDoS upstream |
| Graceful stop without drain loses ~1 in-flight request (S1 stop) | rare user-visible error during an unplanned restart | always drain before planned stops (S2 procedure); newer HAProxy L7-retry handling |
| Health check `/web/health` does not test the database | a node that lost its DB connection still looks UP | add a deeper check (`?db_server_status=1`) with care (DB loss would mark all nodes down at once) and alert on it separately |
| Lab VM performance varies (host suspend, slower host after resume) | absolute numbers drift between runs | comparisons made inside one run; production capacity tests on dedicated hosts |

## Continuity procedures supported by this lab (for the BCP)
1. **Node incident**: automatic (LB). Operator checks stats/Grafana, restarts the container, verifies UP. No user action.
2. **Planned change**: `drain` → wait 0 sessions → `maint` → change → healthy → `ready` (scripted in `s2_rolling_update.sh`).
3. **Overload/attack**: rate limit active by default; tune threshold, clear the stick-table if a legitimate site is blocked.
4. **DB incident**: runbook `s6_db_failover.sh` (promote replica, switch the `db` name, verify Odoo), then rebuild a replica.
5. **Exercise**: `run_all.sh` = repeatable continuity test with measured results (ISO 22301 §8.5 exercising and testing).
