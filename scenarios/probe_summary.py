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
