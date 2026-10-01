# Cross-platform stress on CI runners (2026-09-30)

Three platform bugs were found in two days, each by a new gate on macOS or
Windows: the Windows zero-handle stop, the macOS thread-list-lock hang, and
macOS FP registers. The Linux stress campaigns never touch those platforms.
So the campaign's portable harnesses were run on the CI runners with varied
seeds, every run bounded: `sample` capture on macOS, `cdb` on Windows. The
scripts were `ci/probe/mac.sh` and `ci/probe/win.ps1` on a probe branch.

## Run 1: all harnesses, ~95 min per job (probe run 36753488604, master `c5265d7`)

| runner | runs | failed or stalled |
|---|---:|---:|
| macos-latest ×2 | 1 305 | 1 |
| windows-latest ×2 | 1 287 | 1 |
| windows-11-arm (x64 under emulation) | 600 | 0 |

Harnesses: `stw_mt_property_test` (plain and with poison), `thread_churn_uaf`
child, `index_grow_race` child, `fiber_list_exit_race` child,
`thread_birth_fiber`, and `pattern_fuzz` every fourth round.
`thread_storm` ran on macOS only; it does not build on Windows.

- macOS `stw_mt+diag` seed 40088: stalled, with the collector idle and a
  Parallel worker spinning in `Scheduler#resume` (`scheduler.cr:97`). This is
  the upstream deadlock, crystal-lang/crystal#17486.
- Windows `thread_birth` seed 50014: stalled. The `cdb` capture was lost to a
  bad path filter.

## The Windows `thread_birth` stall, hunted

`thread_birth_fiber 300` in a loop for 75 minutes on three windows-latest
runners, with `cdb` on a stall:

| run | runner speed (runs in 75 min) | stalls |
|---|---|---:|
| before the change | 173 / 4 019 / 4 283 | 2 / 0 / 0 |
| after the change | 332 / 767 / 4 835 | 1 / 0 / 0 |

Every stall was on a runner running about 25 times slower than the others,
13–26 s per run against under 1 s. The one captured stack showed a birth
thread's own `GC.collect` asleep on the collection mutex, an SRWLock, while
the harness's collector thread was inside a stop in `GetThreadContext`. That
fits the collector re-taking an unfair lock the moment it dropped it. It
also fits a run that was simply slower than the 120 s bound on that machine,
and the capture cannot tell the two apart.

Change (`102ed51`): the harness's collector yields after each collection, so
a woken waiter can take the mutex. A 1 ms sleep would also have done it, but
it cut the collections a Linux run overlaps from ~5 000 to 63, which guts
the gate. With the yield it is ~7 300. The product-side unfairness is a
ROADMAP item; it needs a peer collecting in a loop with no gap.

## Run 2: Linux runners (probe run 36786149544, master `44d7995`)

The same macOS script, with gdb for the stall capture. This host is x86_64
only, so these are the first stress hours on Linux aarch64.

| runner | runs | failed or stalled |
|---|---:|---:|
| ubuntu-24.04-arm ×2 | 833 | 0 |
| ubuntu-latest (x86_64) | 493 | 0 |

## What this says

On fast runners there were 0 failures in about 13 000 Windows runs and
1 305 macOS runs, other than the upstream deadlock. The two stall kinds seen
are both livelocks under back-to-back collection (this one, and the
`@roots_lock` one in `../2026-09-30-windows-zero-handle/`), or slow machines.
