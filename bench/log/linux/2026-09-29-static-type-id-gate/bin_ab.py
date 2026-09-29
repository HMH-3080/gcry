#!/usr/bin/env python3
"""Same binary, three env arms run concurrently: old (no extra env), null (no
extra env again), new (NEW_ENV). Each under its own wrk. Per round, from the
trace: pause and static median under load; then /gc-collect and RSS.

usage: env_ab.py BIN ROUNDS EC DURATION KEY=VAL[,KEY=VAL]
"""
import json, os, re, signal, statistics as st, subprocess, sys, time, urllib.request

BIN = sys.argv[1]
NEW_BIN = sys.argv[2]
ROUNDS = int(sys.argv[3])
EC = sys.argv[4]
DUR = sys.argv[5]
NEW = {}
WRK = os.path.expanduser("~/.cache/wrkdeb/bin/wrk")
ARMS = {"old": {}, "null": {}, "new": NEW}


def start(name, env_extra, port):
    trace = f"/tmp/env-ab-{name}.ndjson"
    if os.path.exists(trace):
        os.remove(trace)
    env = dict(os.environ, PORT=str(port), EC_PARALLELISM=EC, GCRY_TRACE="1",
               GCRY_TRACE_FILE=trace, GCRY_TRACE_ALLOC_SAMPLE="0", **env_extra)
    p = subprocess.Popen([NEW_BIN if name == "new" else BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    url = f"http://127.0.0.1:{port}"
    for _ in range(200):
        try:
            urllib.request.urlopen(url + "/", timeout=1).read()
            break
        except Exception:
            time.sleep(0.05)
    return p, url, trace


def rss_kib(pid):
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0


res = {a: {"pause": [], "static": [], "rss": [], "rps": [], "rejects": []} for a in ARMS}
names = list(ARMS)
for r in range(ROUNDS):
    order = names[r % 3:] + names[:r % 3]
    procs = {}
    for i, a in enumerate(order):
        procs[a] = start(a, ARMS[a], 3900 + 10 * (r % 50) + i)
    warm = [subprocess.Popen([WRK, "-t2", "-c100", "-d3s", u + "/json"], stdout=subprocess.DEVNULL)
            for _, u, _ in procs.values()]
    [w.wait() for w in warm]
    marks = {a: os.path.getsize(t) for a, (_, _, t) in procs.items()}
    runs = {a: subprocess.Popen([WRK, "-t2", "-c100", f"-d{DUR}", procs[a][1] + "/json"], stdout=subprocess.PIPE, text=True)
            for a in names}
    outs = {a: w.communicate()[0] for a, w in runs.items()}
    for a in names:
        p, u, t = procs[a]
        end = os.path.getsize(t)
        with open(t, "rb") as f:
            f.seek(marks[a])
            ev = [json.loads(l) for l in f.read(end - marks[a]).decode(errors="ignore").splitlines() if '"collect_end"' in l]
        res[a]["pause"].append(st.median(e["pause_ns"] for e in ev) / 1e3)
        res[a]["static"].append(st.median(e["static_ns"] for e in ev) / 1e3)
        res[a]["rps"].append(float(re.search(r"Requests/sec:\s+([\d.]+)", outs[a]).group(1)))
        urllib.request.urlopen(u + "/gc-collect", timeout=10).read()
        time.sleep(0.3)
        res[a]["rss"].append(rss_kib(p.pid))
        s = json.loads(urllib.request.urlopen(u + "/gc-stats", timeout=10).read())
        res[a]["rejects"].append(s.get("blacklist_skips", -1))
    for a in names:
        p = procs[a][0]
        p.send_signal(signal.SIGTERM)
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    print(f"round {r}: " + "  ".join(f"{a}: pause={res[a]['pause'][-1]:.0f}us rss={res[a]['rss'][-1] // 1024}MB bl={res[a]['rejects'][-1]}" for a in names), flush=True)

print()
for a in names:
    print(f"{a:5s} pause {st.median(res[a]['pause']):.0f}us  static {st.median(res[a]['static']):.0f}us  "
          f"post-GC RSS {st.median(res[a]['rss']) / 1024:.1f}MB  rps {st.median(res[a]['rps']):.0f}  blacklist skips (cum) {st.median(res[a]['rejects'])}")
for other in ("null", "new"):
    for k in ("pause", "rss", "rps"):
        d = [o - b for o, b in zip(res[other][k], res["old"][k])]
        print(f"{other}-old {k}: median {st.median(d):+.1f}  lower in {sum(x < 0 for x in d)}/{len(d)}")
