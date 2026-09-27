#!/usr/bin/env python3
"""Run stw_mt_property_test_hdr --tlab with the dormant opt-in in parallel.

usage: cookie_stress.py BIN [--runs N] [--par P] [--seed0 S] [--nursery] [KEY=VAL ...]
Prints counts of pass / cookie failure / other failure / timeout.
"""
import argparse, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ap = argparse.ArgumentParser()
ap.add_argument("bin")
ap.add_argument("--runs", type=int, default=200)
ap.add_argument("--par", type=int, default=5)
ap.add_argument("--seed0", type=int, default=40000)
ap.add_argument("--nursery", action="store_true")
ap.add_argument("--timeout", type=int, default=180)
ap.add_argument("env", nargs="*")
a = ap.parse_args()
PROBES = {}
env = dict(os.environ, GCRY_BITMAP_ALLOC="0", GCRY_PARALLEL_DORMANT="1")
env.update(kv.split("=", 1) for kv in a.env)

import ctypes
_libc = ctypes.CDLL(None, use_errno=True)

def _allow_ptrace():
    _libc.prctl(0x59616d61, ctypes.c_ulong(0xffffffffffffffff), 0, 0, 0)

def capture_stall(pid, path):
    with open(path, "w") as f:
        live = None
        for tid in sorted(os.listdir(f"/proc/{pid}/task"), key=int):
            base = f"/proc/{pid}/task/{tid}"
            try:
                comm = open(f"{base}/comm").read().strip()
                state = open(f"{base}/stat").read().split(")")[-1].split()[0]
                wchan = open(f"{base}/wchan").read().strip()
            except OSError:
                continue
            f.write(f"task {tid} {comm} state={state} wchan={wchan}\n")
            if live is None and state != "Z":
                live = tid
        if live:
            f.flush()
            r = subprocess.run(["gdb", "-q", "-batch", "-p", live, "-ex", "set pagination off",
                                "-ex", "info threads", "-ex", "thread apply all bt 30"],
                               capture_output=True, text=True, timeout=120)
            f.write(r.stdout[-200000:])

def one(seed):
    cmd = [a.bin, "--tlab", f"--seed={seed}", "--iterations=200", "--workers=2,4"]
    if a.nursery:
        cmd.append("--nursery")
    pr = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                          preexec_fn=_allow_ptrace)
    try:
        out_, _ = pr.communicate(timeout=a.timeout)
    except subprocess.TimeoutExpired:
        os.makedirs("fails", exist_ok=True)
        capture_stall(pr.pid, f"fails/{os.path.basename(a.bin)}-{seed}-stall.log")
        pr.kill()
        pr.communicate()
        return seed, "timeout", ""
    class P: pass
    p = P(); p.returncode = pr.returncode; p.stdout = out_; p.stderr = ""
    out = p.stdout + p.stderr
    probe = out.count("PROBE")
    for line in out.splitlines():
        if line.startswith("PROBE"):
            PROBES[line] = PROBES.get(line, 0) + 1
    if p.returncode != 0:
        os.makedirs("fails", exist_ok=True)
        open(f"fails/{os.path.basename(a.bin)}-{seed}.log", "w").write(out)
    if p.returncode == 0:
        return seed, "pass" + ("+probe" if probe else ""), ""
    kind = ("cookie" if "cookie broken" in out else "other") + (f"+probe{probe}" if probe else "")
    tail = [l for l in out.splitlines() if "ERROR" in l or "gcry:" in l][:3]
    return seed, kind, " | ".join(tail)

counts = {}
with ThreadPoolExecutor(a.par) as ex:
    for seed, kind, tail in ex.map(one, range(a.seed0, a.seed0 + a.runs)):
        counts[kind] = counts.get(kind, 0) + 1
        if kind != "pass":
            print(f"seed={seed} {kind} {tail[:300]}", flush=True)
print(" ".join(f"{k}={v}" for k, v in sorted(counts.items())), f"env={a.env}")
for k, v in sorted(PROBES.items()):
    print(f"  {v:6d}  {k}")
