import itertools, os, subprocess, sys, threading, time
arm = sys.argv[1]; lanes = int(sys.argv[2]); seeds = int(sys.argv[3])
exe = f"./hdr-{arm}"
DIAG = {"GCRY_POISON_FREED": "1", "GCRY_SEGV_REPORT": "1", "GCRY_STW_WATCHDOG_MS": "10000"}
CFG = [
  ("tlab", ["--tlab"], {}),
  ("tlab_nursery", ["--tlab", "--nursery"], DIAG),
  ("tlab_dormant", ["--tlab"], {"GCRY_PARALLEL_DORMANT": "1", **DIAG}),
  ("tlab_nursery_dormant", ["--tlab", "--nursery"], {"GCRY_PARALLEL_DORMANT": "1"}),
]
jobs = [(c, s) for s in range(1, seeds + 1) for c in CFG]
lock = threading.Lock(); it = iter(jobs)
out = open(f"res-{arm}.tsv", "w", buffering=1)
os.makedirs(f"logs-{arm}", exist_ok=True)
def lane():
    while True:
        with lock:
            try: (name, args, env), seed = next(it)
            except StopIteration: return
        t = time.time()
        log = f"logs-{arm}/{name}-{seed}.log"
        with open(log, "w") as f:
            try:
                rc = subprocess.run([exe, *args, f"--seed={seed}", "--iterations=200", "--workers=2,4"],
                    env={**os.environ, "GCRY_BITMAP_ALLOC": "0", **env}, stdout=f, stderr=subprocess.STDOUT, timeout=300).returncode
            except subprocess.TimeoutExpired:
                rc = 124
        out.write(f"{name}\t{seed}\t{rc}\t{time.time()-t:.1f}\n")
        if rc == 0: os.remove(log)
ts = [threading.Thread(target=lane) for _ in range(lanes)]
[t.start() for t in ts]; [t.join() for t in ts]
