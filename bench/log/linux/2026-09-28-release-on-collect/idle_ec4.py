#!/usr/bin/env python3
"""EC4 Kemal: load, then go idle with no GC.collect; RSS before and after the idle collector."""
import os, re, signal, subprocess, sys, time, urllib.request

BIN = sys.argv[1]
WRK = os.path.expanduser("~/.cache/wrkdeb/bin/wrk")


def rss(pid):
    return int(re.search(r"VmRSS:\s+(\d+)", open(f"/proc/{pid}/status").read()).group(1)) // 1024


for label, extra in (("default", {}), ("keep", {"GCRY_PARALLEL_RELEASE_ON_COLLECT": "0"})):
    port = "3710" if label == "default" else "3711"
    env = dict(os.environ, PORT=port, EC_PARALLELISM="4", GCRY_IDLE_RELEASE_MS="2000", **extra)
    p = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1).read()
                break
            except Exception:
                time.sleep(0.05)
        subprocess.run([WRK, "-t2", "-c100", "-d8s", f"http://127.0.0.1:{port}/json"], capture_output=True)
        after_load = rss(p.pid)
        time.sleep(6)
        after_idle = rss(p.pid)
        print(f"{label}: RSS after load {after_load} MB, after 6 s idle {after_idle} MB")
    finally:
        p.send_signal(signal.SIGTERM)
        p.wait()
