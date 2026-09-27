# A parked fiber is scanned from its saved SP under multi-mutator STW

**Date:** 2026-09-27 · host: QEMU x86_64, 12 vCPU · Crystal 1.21.0
`--release` · Kemal `/json`, `wrk -t2 -c100 -d10` after a 2 s warm-up,
arms rotated per round, pause p50 from `/gc-stats`.

## What changed

Under multi-mutator STW every parked fiber was scanned from 256 KiB below its
saved `stack_top` (`GCRY_STW_STACK_LAG`). The rule was: a fiber in transit may
report a stale `stack_top`, and a thread on its stack is only ruled out if
the stop recorded an SP for **every** thread.

The 2026-09-14 item declined the fix because that last condition never held:
0 of 34 989 lag scans at Kemal EC4 had a complete SP table
(`../2026-09-14-parked-fiber-lag-ceiling/`). The cause was structural. SYSMON
and the idle collector are never signalled, so they never have an SP.

**They also never run a user fiber.** Each thread only ever runs its own main
fiber, so neither can be on a pool fiber's stack. Now an exempt thread
(`stw_signal_exempt?`) with no SP no longer marks the table incomplete. With
a complete table and `running?` false, the fiber is scanned from its saved
`stack_top`, as on EC1. That is not an STW protocol change: the same threads
are stopped, and the same SPs are recorded.

Why `running?` false is enough once no thread is on the stack
(`fiber/context/x86_64-sysv.cr`, `aarch64-generic.cr`):

- **Switching out,** `swapcontext` pushes every callee-saved register, stores
  SP into `stack_top`, and only then sets `resumable = 1`. Everything it
  saved is at or above `stack_top`.
- **Switching in,** it sets the target's `resumable = 0` **before** SP moves
  onto the target's stack. A fiber that reads parked therefore has no frame
  below `stack_top`.
- A thread caught between those stores is either still on the old stack or
  already on this one. In the second case the SP check finds it and scans
  from that SP, as before.

The lag remains for what the check cannot see: a non-exempt thread with no
recorded SP.

`GCRY_PARKED_FIBER_SP=0` restores the lag for every parked fiber.

## Results

EC1 with one extra thread (`EXTRA_THREADS=1`, the ROADMAP item "One extra
thread costs an EC1 program 2.7× pause"), 8 rounds (`psp_ec1.py`):

| arm | pause p50 | req/s |
|---|---:|---:|
| no extra thread | 0.496 ms | 45 721 |
| extra thread, `GCRY_PARKED_FIBER_SP=0` | 1.999 ms | 44 310 |
| extra thread, default | **0.589 ms** | 45 586 |

The fix is lower in 8 of 8 rounds (−1.415 ms, range 1.334–1.461). That is
below the ceiling a 4 KiB lag gave (0.949 ms, `lag_ec1.py`), because the
pagemap probe is skipped too.

EC4, 12 rounds with a null arm (`psp_ec4.py`: off, off again, on):

| arm | pause p50 | req/s |
|---|---:|---:|
| `GCRY_PARKED_FIBER_SP=0` | 2.525 ms | 262 798 |
| same, null | 2.533 ms | 259 805 |
| default | **0.808 ms** | 264 229 |

- Pause: lower in 12 of 12 rounds (−1.730 ms, range 1.655–1.802).
- Throughput on/off: 1.030 (0.811–1.227), against a null of 0.967. That is
  inside the noise. A 10-round run before it read on/off 0.93 on medians,
  which the per-round ratios did not bear out.

## Soundness evidence

`parked_sp.cr`: 200 fibers on a 4-thread Parallel context, each holding a
heap object only in its own frame, parked on a channel through 3 collections.

| arm | parked-SP scans | lag scans | every object alive |
|---|---:|---:|---|
| default | 618 | 0 | yes |
| `GCRY_PARKED_FIBER_SP=0` | 0 | 618 | yes |
| default, 400 fibers, `GCRY_POISON_FREED=1` | 1218 | 0 | yes |

Local gates, all green: `stw-mt-property-test-short`, `nested-spawn-uaf`,
`scheduler-roots`, `stw-lag-pause`, `thread-churn-uaf`, `greg-roots`,
`idle-thread-roots`, `stw-slot-precision`.

Stress campaign on the change: the campaign lanes in the default
configuration, built from `db50034`, 5 lanes, 2 h (`campaign-summary.md`).
It ran **1674 runs over 10.1 lane-hours: 0 failures, 0 timeouts**. That
includes 458 `stw_mt` runs (Parallel workers at 2, 4 and 8, diagnostics on
in two thirds of them), 152 `thread_storm` and 152 `pattern_fuzz+diag`.

`make soft-soak-ec4` (Kemal EC4, `wrk -c100 -d8 /json` × 40, the Parallel
correctness gate) on `986e8c0`: **40/40, soft 0, hard 0**. With
`GCRY_POISON_FREED=1` it was **40/40, soft 0, hard 0** as well.

CI soak, 3 × 5 h at `--workers=4` so that every collection is multi-mutator
(run `36341297555`): PENDING.
