#!/usr/bin/env python3
"""Paired dormant A/B on the soft-soak shape: EC4 Kemal, wrk -c100 -d8 /json.

Arms off / on / off2 in rotated order per round; ratios per round.
usage: paired_kemal.py BIN ROUNDS
"""
import os, re, signal, statistics, subprocess, sys, time, urllib.request

BIN = sys.argv[1]
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 10
WRK = os.path.expanduser("~/.cache/wrkdeb/bin/wrk")
ARMS = {"off": {"GCRY_PARALLEL_RELEASE_ON_COLLECT": "0"}, "on": {}, "off2": {"GCRY_PARALLEL_RELEASE_ON_COLLECT": "0"}}
port = 3400

def run(env):
    global port
    port += 1
    e = dict(os.environ, EC_PARALLELISM="4", PORT=str(port), **env)
    srv = subprocess.Popen([BIN], env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1).read()
                break
            except Exception:
                time.sleep(0.1)
        out = subprocess.run([WRK, "-c", "100", "-d", "8", f"http://127.0.0.1:{port}/json"],
                             capture_output=True, text=True).stdout
        rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
        rss = int(open(f"/proc/{srv.pid}/status").read().split("VmRSS:")[1].split()[0])
        return rps, rss
    finally:
        srv.send_signal(signal.SIGTERM)
        try:
            srv.wait(5)
        except subprocess.TimeoutExpired:
            srv.kill()
            srv.wait()

res = {a: [] for a in ARMS}
order = list(ARMS)
for r in range(ROUNDS):
    for a in order[r % 3:] + order[:r % 3]:
        res[a].append(run(ARMS[a]))
    print(f"round {r}: " + " ".join(f"{a}={res[a][-1][0]:.0f}" for a in ARMS), flush=True)

def ratio(a, b, k):
    xs = [x[k] / y[k] for x, y in zip(res[a], res[b])]
    return f"{statistics.median(xs):.3f} ({min(xs):.3f}-{max(xs):.3f})"

for a in ARMS:
    print(f"{a}: req/s med {statistics.median(x[0] for x in res[a]):.0f}  rss-at-end med {statistics.median(x[1] for x in res[a])/1024:.1f} MB")
print(f"on/off   req/s {ratio('on', 'off', 0)}  rss {ratio('on', 'off', 1)}")
print(f"off2/off req/s {ratio('off2', 'off', 0)}  (null)")
