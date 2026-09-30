# Stress campaign-037 on `44852e5` (2026-09-30)

Same runner and jobs as campaign-036. Its Linux code is what ships in 0.32.0:
everything after `44852e5` touches macOS, Windows, CI or harnesses only. The
runner is changed in one respect: a stalled run now has every descendant
captured, not only the leader, and its whole process group is killed.

**3 287 runs, 20.0 lane-hours, 0 failures, 5 timeouts.**

| lane | runs | failed | timed out |
|---|---:|---:|---:|
| `churn` | 292 | 0 | 0 |
| `churn_hdr` | 292 | 0 | 0 |
| `dormant_flush` | 291 | 0 | 0 |
| `index_grow` | 292 | 0 | 0 |
| `pattern_fuzz+diag` | 288 | 0 | 1 |
| `stw_mt` | 292 | 0 | 2 |
| `stw_mt+diag` | 584 | 0 | 2 |
| `stw_mt_hdr_tlab` | 292 | 0 | 0 |
| `stw_mt_hdr_tlab_nursery` | 292 | 0 | 0 |
| `thread_storm` | 291 | 0 | 0 |

(Figures as of 4.0 h wall, with the runner finishing its last in-flight runs.)

## The timeouts

- **`stw_mt` 20050, 20111; `stw_mt+diag` 20045, 20280: upstream.** Each
  has two Parallel workers spinning at `parallel/scheduler.cr:97` and no gcry
  frame in any thread: crystal-lang/crystal#17486.
- **`pattern_fuzz+diag` seed 20279: a cycle in a large-object freelist
  bucket.** In the Stride phase main spun in `cache_large_chunk`'s walk to the
  bucket's tail (`heap.cr:2266`), under `GC.malloc_atomic` → `maybe_collect`
  → the lazy sweep → `sweep_large_one`. That walk ends unless the chain has a
  cycle. The same seed passed 4 of 4 locally. This is the second
  `pattern_fuzz` hang in two campaigns and the second in a large-chunk
  structure: campaign-036's was the chunk list itself, in `unlink_chunk`
  under `trim_large_cache`. Neither mechanism is known yet.

`dormant_flush`, whose two stalls in campaign-036 could not be classified,
had none in 291 runs here.
