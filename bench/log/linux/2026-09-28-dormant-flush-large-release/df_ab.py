#!/usr/bin/env python3
"""Run two dormant_flush_race binaries side by side under the same load.

usage: df_ab.py OLD NEW PAR ROUNDS
Each round starts PAR copies of each binary at once; counts failing children.
"""
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

old, new, par, rounds = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
env = dict(os.environ, GCRY_SEGV_REPORT="1")
os.makedirs("df_fails", exist_ok=True)


def one(args):
    label, binary, r, k = args
    try:
        p = subprocess.run([binary], env=env, capture_output=True, text=True, timeout=600)
        rc = p.returncode
        out = p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        rc, out = "timeout", ""
    if rc != 0:
        open(f"df_fails/{label}-{r}-{k}.log", "w").write(out)
    return label, rc


tally = {"old": [0, 0], "new": [0, 0]}
with ThreadPoolExecutor(2 * par) as ex:
    for r in range(rounds):
        jobs = [(lab, b, r, k) for k in range(par) for lab, b in (("old", old), ("new", new))]
        for lab, rc in ex.map(one, jobs):
            tally[lab][0] += 1
            tally[lab][1] += rc != 0
        print(f"round {r}: old {tally['old'][1]}/{tally['old'][0]} new {tally['new'][1]}/{tally['new'][0]}", flush=True)
