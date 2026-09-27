#!/usr/bin/env python3
"""Ceiling of the parked-fiber-SP proposal at EC1 + one extra thread.

Arms, rotated per round: none (no extra thread, reference), shipped (extra
thread, lag 256 KiB), narrow (extra thread, lag 4 KiB = the proposal's best).
usage: lag_ec1.py BIN ROUNDS
"""
import json, os, re, signal, statistics, subprocess, sys, time, urllib.request

BIN = sys.argv[1]
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 8
WRK = os.path.expanduser("~/.cache/wrkdeb/bin/wrk")
ARMS = {
    "none": {"EC_PARALLELISM": "4", "GCRY_PARKED_FIBER_SP": "0"},
    "shipped": {"EC_PARALLELISM": "4", "GCRY_PARKED_FIBER_SP": "0"},
    "narrow": {"EC_PARALLELISM": "4"},
}
port = 3600


def run(env):
    global port
    port += 1
    url = f"http://127.0.0.1:{port}"
    srv = subprocess.Popen([BIN], env=dict(os.environ, PORT=str(port), **env),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            try:
                urllib.request.urlopen(url + "/", timeout=1).read()
                break
            except Exception:
                time.sleep(0.05)
        subprocess.run([WRK, "-t2", "-c100", "-d2s", url + "/json"], capture_output=True)
        out = subprocess.run([WRK, "-t2", "-c100", "-d10s", url + "/json"], capture_output=True, text=True).stdout
        rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
        s = json.loads(urllib.request.urlopen(url + "/gc-stats").read())
        return {"rps": rps, "pause": s["pause_p50_ns"] / 1e6, "roots": s.get("last_phase_roots_ns", 0) / 1e3}
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
    print(f"round {r}: " + " ".join(f"{a}={res[a][-1]['pause']:.3f}ms" for a in ARMS), flush=True)

med = statistics.median
for a in ARMS:
    print(f"{a}: pause p50 {med(x['pause'] for x in res[a]):.3f} ms  req/s {med(x['rps'] for x in res[a]):.0f}")
d = [s["pause"] - n["pause"] for s, n in zip(res["shipped"], res["narrow"])]
print(f"shipped - narrow pause: median {med(d):.3f} ms (min {min(d):.3f}, max {max(d):.3f}); narrow lower in {sum(x > 0 for x in d)}/{len(d)}")

r_on = [n["rps"] / s["rps"] for s, n in zip(res["shipped"], res["narrow"])]
r_null = [n["rps"] / s["rps"] for s, n in zip(res["shipped"], res["none"])]
print(f"req/s on/off: median {med(r_on):.3f} (min {min(r_on):.3f}, max {max(r_on):.3f}); on higher in {sum(x > 1 for x in r_on)}/{len(r_on)}")
print(f"req/s off2/off (null): median {med(r_null):.3f} (min {min(r_null):.3f}, max {max(r_null):.3f})")
