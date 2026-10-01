# Stress campaign-041 on `5309d38` (2026-10-01)

Campaign-039's jobs, five lanes for five hours, on a tree with the Darwin
`start_world` fix and the harness changes of 2026-10-01. Linux's own collector
code did not change between 039 and this tree, so this is mostly more hours.

**4 219 runs, 25.1 lane-hours, 0 failures, 2 timeouts.**

| lane | runs | failed | timed out |
|---|---:|---:|---:|
| `churn_hdr` | 383 | 0 | 0 |
| `churn` | 383 | 0 | 0 |
| `dormant_flush` | 383 | 0 | 0 |
| `index_grow` | 383 | 0 | 0 |
| `pattern_fuzz+diag` | 384 | 0 | 0 |
| `stw_mt+diag` | 768 | 0 | 2 |
| `stw_mt_hdr_tlab_nursery` | 384 | 0 | 0 |
| `stw_mt_hdr_tlab` | 384 | 0 | 0 |
| `stw_mt` | 384 | 0 | 0 |
| `thread_storm` | 383 | 0 | 0 |

Both timeouts are `stw_mt` seeds 20083 and 20258. Each has the upstream shape:
two threads at `parallel/scheduler.cr:97`, gcry frames only in the watchdog
and the idle collector, both asleep, and no STW report
(crystal-lang/crystal#17486).

`pattern_fuzz` hit no cycle bound again. With campaigns 038–040 that is about
1 560 runs of the bounded bucket walk.
