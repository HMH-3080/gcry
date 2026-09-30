# Stress campaign-039 on `c5265d7` (2026-09-30)

Same runner and jobs as campaign-038. This tree adds the sweep's per-empty-chunk
disposition counters (`parallel-dormant`'s diagnostic) to the hot sweep loop.

**2 960 runs, 20.1 lane-hours, 0 failures, 1 timeout.**

| lane | runs | failed | timed out |
|---|---:|---:|---:|
| `churn_hdr` | 269 | 0 | 0 |
| `churn` | 269 | 0 | 0 |
| `dormant_flush` | 269 | 0 | 0 |
| `index_grow` | 269 | 0 | 0 |
| `pattern_fuzz+diag` | 269 | 0 | 0 |
| `stw_mt+diag` | 538 | 0 | 0 |
| `stw_mt_hdr_tlab_nursery` | 269 | 0 | 0 |
| `stw_mt_hdr_tlab` | 269 | 0 | 0 |
| `stw_mt` | 270 | 0 | 1 |
| `thread_storm` | 269 | 0 | 0 |

The timeout, `stw_mt` seed 20085, has the upstream shape: two Parallel workers
at `parallel/scheduler.cr:97` and no collector frame
(crystal-lang/crystal#17486).

`pattern_fuzz`: 0 cycles again. Since the two walks were bounded (campaigns
038–039), that is 0 in about 570 runs.
