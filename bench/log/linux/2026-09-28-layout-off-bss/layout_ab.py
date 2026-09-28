#!/usr/bin/env python3
"""Batched resume A/B: old, null (old again) and new Kemal EC4 servers run
concurrently under the same load, each with its own wrk. Per collection under
load, from GCRY_TRACE: pause, stw_start, stw_stop.

usage: resume_ab.py OLD NEW ROUNDS [EC] [DURATION]
"""
import json, os, re, signal, statistics as st, subprocess, sys, time, urllib.request

OLD, NEW = sys.argv[1], sys.argv[2]
ROUNDS = int(sys.argv[3]) if len(sys.argv) > 3 else 6
EC = sys.argv[4] if len(sys.argv) > 4 else "4"
DUR = sys.argv[5] if len(sys.argv) > 5 else "15s"
WRK = os.path.expanduser("~/.cache/wrkdeb/bin/wrk")
ARMS = {"old": OLD, "null": OLD, "new": NEW}
KEYS = ["pause_ns", "static_ns", "roots_ns", "mark_ns"]


def start(name, binary, port):
    trace = f"/tmp/resume-ab-{name}.ndjson"
    if os.path.exists(trace):
        os.remove(trace)
    env = dict(os.environ, PORT=str(port), EC_PARALLELISM=EC, GCRY_TRACE="1",
               GCRY_TRACE_FILE=trace, GCRY_TRACE_ALLOC_SAMPLE="0")
    p = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    url = f"http://127.0.0.1:{port}"
    for _ in range(200):
        try:
            urllib.request.urlopen(url + "/", timeout=1).read()
            break
        except Exception:
            time.sleep(0.05)
    return p, url, trace


res = {a: {k: [] for k in KEYS + ["rps"]} for a in ARMS}
for r in range(ROUNDS):
    procs = {}
    names = list(ARMS)
    order = names[r % 3:] + names[:r % 3]
    for i, a in enumerate(order):
        procs[a] = start(a, ARMS[a], 3800 + 10 * r + i)
    procs = {a: procs[a] for a in names}
    warm = [subprocess.Popen([WRK, "-t2", "-c100", "-d3s", u + "/json"], stdout=subprocess.DEVNULL)
            for _, u, _ in procs.values()]
    [w.wait() for w in warm]
    marks = {a: os.path.getsize(t) for a, (_, _, t) in procs.items()}
    runs = {a: subprocess.Popen([WRK, "-t2", "-c100", f"-d{DUR}", u + "/json"], stdout=subprocess.PIPE, text=True)
            for a, (_, u, _) in procs.items()}
    outs = {a: w.communicate()[0] for a, w in runs.items()}
    line = []
    for a, (p, _, t) in procs.items():
        end = os.path.getsize(t)
        p.send_signal(signal.SIGTERM)
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        with open(t, "rb") as f:
            f.seek(marks[a])
            data = f.read(end - marks[a]).decode(errors="ignore")
        ev = [json.loads(l) for l in data.splitlines() if '"collect_end"' in l]
        for k in KEYS:
            res[a][k].append(st.median(e[k] for e in ev) / 1e3 if ev else float("nan"))
        res[a]["rps"].append(float(re.search(r"Requests/sec:\s+([\d.]+)", outs[a]).group(1)))
        line.append(f"{a}: n={len(ev)} pause={res[a]['pause_ns'][-1]:.0f}us static={res[a]["static_ns"][-1]:.0f}us")
    print(f"round {r}: " + "  ".join(line), flush=True)

print()
for a in ARMS:
    print(f"{a:5s} " + "  ".join(f"{k} p50-of-medians {st.median(res[a][k]):.0f}us" for k in KEYS)
          + f"  rps {st.median(res[a]['rps']):.0f}")
for other in ("null", "new"):
    for k in ("pause_ns", "static_ns"):
        d = [o - b for o, b in zip(res[other][k], res["old"][k])]
        print(f"{other}-old {k}: median {st.median(d):+.0f}us  lower in {sum(x < 0 for x in d)}/{len(d)}")
