# The pause after this round of work, all changes together

**Date:** 2026-09-29 · tree `cbac3e0`, against 0.30.0.

Four changes since 0.30.0 touch the pause:
- layout tables off the static roots (`../2026-09-28-layout-off-bss/`);
- no probe of pooled fiber stacks (`../2026-09-28-fiber-probe/`);
- batched resume (`../2026-09-28-batched-resume/`);
- the TLAB claim retired, which does not touch the default path.

## Paired, locally

`../2026-09-28-fiber-probe/probe_ab.py` compared `f0749ba` (before all
three pause changes) as old and null with `cbac3e0` as new. Kemal ran at
EC1, 9 rounds, concurrently, with a stress campaign on the host.

| | pause | roots | static | req/s |
|---|---:|---:|---:|---:|
| old | 651 µs | 168 µs | 145 µs | 65 073 |
| null | 652 µs | 169 µs | 145 µs | 66 202 |
| new | **501 µs** | 141 µs | 13 µs | 66 678 |

The pause was lower in 9 of 9 rounds, by 145–165 µs (−23%). Throughput did
not move.

## CI runners, not paired

`workflow_dispatch` run `36491413689` ran `bench/sound_matrix.py` for 8
rounds on the GitHub runners. The table compares its tuned arm with 0.30.0's
run (`../2026-09-28-sound-matrix/`, 10 rounds). These are different runners
on different days, so only a large, same-direction difference means much.

| tuned pause, median | Linux 0.30.0 | Linux now | macOS 0.30.0 | macOS now |
|---|---:|---:|---:|---:|
| EC1 | 1.234 ms | **0.736 ms** (−40%) | 0.808 ms | **0.613 ms** (−24%) |
| EC1 + one thread | 1.405 ms | **0.892 ms** (−37%) | 0.897 ms | **0.671 ms** (−25%) |
| EC4 | 1.697 ms | **1.207 ms** (−29%) | 1.107 ms | 1.055 ms (−5%) |

The same comparison of req/s moved in both directions: Linux EC1 −9%, EC4
+3%; macOS EC1 +1%, EC4 −21%, EC1 + thread +12%. RSS was within 1% except
macOS EC1 + thread (+4%). The paired local run above shows no throughput
change, so the req/s swings are read as runner variance. [INFERENCE] The
pause drops have one sign on both platforms and every shape, and match the
paired measurements.

The run's own paired sound ÷ tuned ratios, pause: Linux 0.98× / 5.22× /
3.77×, macOS 1.05× / 5.49× / 4.19×. These are larger multipliers than
0.30.0's because the tuned denominator shrank. `GCRY_SOUND=1` still scans
every parked fiber whole and takes none of the tuned path's savings.

## Stress campaign on `cbac3e0`

The default-configuration campaign ran five lanes for 5 h over the tree with
all four changes (`campaign-032-summary.md`). The `dormant_flush` lane also
had `GCRY_TRACE_LARGE=1` and hang capture on. **4 784 runs, 25 lane-hours,
0 failures.** There were 4 timeouts:
- `stw_mt` seed 20069;
- `stw_mt+diag` seeds 20116 and 20396;
- `stw_mt_hdr_tlab_nursery` seed 20414.

Each capture shows two worker threads in `parallel/scheduler.cr:97` `resume`
and no collector frame on any thread. That is Crystal's scheduler deadlock,
crystal-lang/crystal#17486 (fix in #17491), and not a stop that failed to
end.
