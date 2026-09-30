# Stress campaign-038 on `ea3f167` (2026-09-30)

Same runner and jobs as campaign-037. This tree bounds and reports both
large-chunk walks that spun in earlier campaigns (`unlink_chunk`'s
predecessor walk and `cache_large_chunk`'s bucket tail walk), so a recurrence
aborts with a named cycle instead of timing out.

**3 405 runs, 20.1 lane-hours, 0 failures, 4 timeouts.**

| lane | runs | failed | timed out |
|---|---:|---:|---:|
| `churn` | 309 | 0 | 0 |
| `churn_hdr` | 309 | 0 | 0 |
| `dormant_flush` | 309 | 0 | 0 |
| `index_grow` | 309 | 0 | 0 |
| `pattern_fuzz+diag` | 310 | 0 | 0 |
| `stw_mt` | 310 | 0 | 1 |
| `stw_mt+diag` | 620 | 0 | 2 |
| `stw_mt_hdr_tlab` | 310 | 0 | 0 |
| `stw_mt_hdr_tlab_nursery` | 310 | 0 | 1 |
| `thread_storm` | 309 | 0 | 0 |

All four timeouts (`stw_mt+diag` 20126 and 20271, `stw_mt` 20216,
`stw_mt_hdr_tlab_nursery` 20176) have the upstream shape: two Parallel workers
at `parallel/scheduler.cr:97`, and no collector, heap, mark or sweep frame in
any thread (crystal-lang/crystal#17486).

`pattern_fuzz`: 0 cycles in 310 runs. Across campaigns 036–038 that is 2 in
about 812, neither since the walks were bounded.
