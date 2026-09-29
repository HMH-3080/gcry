4784 runs, 25.1 lane-hours, wall 5.0 h

| lane | runs | failed | timed out | lane-hours |
|---|---:|---:|---:|---:|
| `churn` | 435 | 0 | 0 | 0.1 |
| `churn_hdr` | 435 | 0 | 0 | 0.1 |
| `dormant_flush` | 435 | 0 | 0 | 7.6 |
| `index_grow` | 435 | 0 | 0 | 0.8 |
| `pattern_fuzz+diag` | 435 | 0 | 0 | 14.8 |
| `stw_mt` | 435 | 0 | 1 | 0.3 |
| `stw_mt+diag` | 870 | 0 | 2 | 0.6 |
| `stw_mt_hdr_tlab` | 435 | 0 | 0 | 0.3 |
| `stw_mt_hdr_tlab_nursery` | 435 | 0 | 1 | 0.5 |
| `thread_storm` | 434 | 0 | 0 | 0.1 |

- `stw_mt` seed 20069: rc=TIMEOUT after 300 s
- `stw_mt+diag` seed 20116: rc=TIMEOUT after 300 s
- `stw_mt+diag` seed 20396: rc=TIMEOUT after 300 s
- `stw_mt_hdr_tlab_nursery` seed 20414: rc=TIMEOUT after 300 s
