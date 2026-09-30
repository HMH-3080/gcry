# Stress campaign-036 on `cda5dec` (2026-09-29)

Varied seeds, 5 lanes, 4 h deadline, on this host (QEMU x86_64, 12 vCPU).
Runner and job list as in campaign-035. Every run is bounded, and a run past
its deadline gets a thread census and a gdb backtrace before the kill.

**2 379 runs, 17.4 lane-hours, 0 failures, 4 timeouts.**

| lane | runs | failed | timed out |
|---|---:|---:|---:|
| `churn` | 217 | 0 | 0 |
| `churn_hdr` | 217 | 0 | 0 |
| `dormant_flush` | 215 | 0 | 2 |
| `index_grow` | 217 | 0 | 0 |
| `pattern_fuzz+diag` | 214 | 0 | 1 |
| `stw_mt` | 217 | 0 | 0 |
| `stw_mt+diag` | 434 | 0 | 0 |
| `stw_mt_hdr_tlab` | 217 | 0 | 1 |
| `stw_mt_hdr_tlab_nursery` | 217 | 0 | 0 |
| `thread_storm` | 216 | 0 | 0 |

## The timeouts

- **`stw_mt_hdr_tlab` seed 20127: upstream.** Two Parallel workers spin in
  `Scheduler#resume` (`parallel/scheduler.cr:97`) and there is no collector
  frame anywhere. This is crystal-lang/crystal#17486, which reproduces under
  Boehm (`../2026-09-25-parallel-scheduler-deadlock/`). Not counted against
  gcry.
- **`pattern_fuzz+diag` seed 20102: a chunk-list cycle.** Main spun for
  900 s in `unlink_chunk`'s predecessor walk, under `GC.free` →
  `trim_large_cache`, and every other thread was asleep. The walk ends
  unless the list has a cycle. The same seed passed 3 of 3 locally, and
  campaigns 030–035 had 0 in about 1 080 `pattern_fuzz` runs. The walk is now
  bounded and aborts with the cycle's entry chunk, length and flags
  (`47beee8`). ROADMAP open item.
- **`dormant_flush` seeds 20214 and 20215: unclassified.** Both started within
  37 s of each other (20:19–20:20 UTC) and both outlived the 600 s deadline,
  where runs normally take 57–118 s. There were 0 such timeouts in the other
  213 runs of this lane, or in 1 082 runs of it across campaigns 030–035
  (034's results were lost). The capture recorded only
  the harness's **parent**: main was in its 20 ms child-polling loop, having
  read 4 child results, and SYSMON was asleep. `bench/bounded_child.cr` kills
  a child at 120 s, but no child capture was written to the capture
  directory, so either no child reached its deadline or the parent's own wait
  stopped advancing. The capture cannot say which. The runner now captures
  every descendant of a stalled run and kills its whole process group
  (campaign-037 onward).
