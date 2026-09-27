#!/usr/bin/env python3
"""Paired A/B for GCRY_PARALLEL_DORMANT on the MT tree probe, with a null arm.

Each round runs off, on, off2 in a rotated order; ratios are per round.
"""
import os, re, statistics, subprocess, sys

BIN = sys.argv[1]
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 12
EXTRA = dict(kv.split("=", 1) for kv in sys.argv[3:])
ARMS = {"off": {}, "on": {"GCRY_PARALLEL_DORMANT": "1"}, "off2": {}}

def run(env):
    e = dict(os.environ, **EXTRA, **env)
    out = subprocess.run([BIN], env=e, capture_output=True, text=True, check=True).stdout
    return {k: float(v) for k, v in re.findall(r"(\w+)=([\d.]+)", out)}

res = {a: [] for a in ARMS}
order = list(ARMS)
for r in range(ROUNDS):
    rot = order[r % 3:] + order[:r % 3]
    for a in rot:
        res[a].append(run(ARMS[a]))

def ratios(a, b, k):
    return [x[k] / y[k] for x, y in zip(res[a], res[b])]

def fmt(xs):
    return f"{statistics.median(xs):.3f} ({min(xs):.3f}–{max(xs):.3f})"

print(f"rounds={ROUNDS} extra={EXTRA}")
for a in ARMS:
    print(f"  {a}: ms={statistics.median(x['ms'] for x in res[a]):.1f} "
          f"rss={statistics.median(x['rss_kib'] for x in res[a])/1024:.1f}MB "
          f"hwm={statistics.median(x['hwm_kib'] for x in res[a])/1024:.1f}MB")
print(f"on/off   ms {fmt(ratios('on', 'off', 'ms'))}  rss {fmt(ratios('on', 'off', 'rss_kib'))}  hwm {fmt(ratios('on', 'off', 'hwm_kib'))}")
print(f"off2/off ms {fmt(ratios('off2', 'off', 'ms'))}  rss {fmt(ratios('off2', 'off', 'rss_kib'))}  (null)")
