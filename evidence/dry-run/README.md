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
