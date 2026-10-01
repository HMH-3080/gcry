# Parallel mark: a late worker took the next phase's work (2026-10-01)

`GCRY_PARALLEL_MARK=N` (experimental) reclaimed live objects. The symptoms
were explicitly rooted blocks read back as freed (`root 0 DEAD …
0xdeadf2eedeadf2ee` under `GCRY_POISON_FREED`), SIGSEGV at wild addresses,
`pthread_mutex_lock: Invalid argument` on the fiber list's mutex,
`Negative WaitGroup counter` and arithmetic overflows: runtime objects whose
memory had been handed out again.

## Found by

Campaign-042 was the first to run lanes with `GCRY_PARALLEL_MARK=4`. One
`stw_mt` run deadlocked inside its own exception report after
`pthread_mutex_lock: Invalid argument`. A baseline on the tree before the
day's parallel-mark changes (`5309d38`) failed far more often, so the defect
was older than them.

## Mechanism

A collection runs `mark_loop` more than once: the trace, and then the
finalizer pass (`enqueue_unreachable_finalizers` pushes candidates and drains
again). Between the two, the master pushes onto `@mark_stack` with no lock,
because `mark_stack_push` reads `@mark_parallel` false. A helper that had read
`while @mark_parallel` as true just before the cycle ended could still reach
`pop_mark_batch`. It then took entries the master was pushing and popping
without the lock, and pushed its children with no lock either. Entries were
lost and their objects went unmarked.

The start of a cycle had the same gap in the other direction. On a weakly
ordered CPU, a helper that saw `@mark_parallel = true` was not guaranteed to
see the master's unlocked pushes made just before it.

## Fix

Both transitions of `@mark_parallel` happen under `@mark_lock`, and
`pop_mark_batch` re-reads it under the lock and takes nothing once the cycle
has ended. The termination argument is unchanged. The master ends the cycle
only after seeing `busy == 0` and an empty stack, and only busy workers push,
so nothing can be taken between that check and the transition.

## Evidence

Same lanes and same build mode; failures are runs that crashed, failed the
property check, or hung:

| binary | `stw_mt` (`+pm4`, `+pm4+diag`) | `thread_storm+pm4` |
|---|---:|---:|
| `5309d38` (before the day's parallel-mark work) | 17 of 1 749 | 525 of 3 345 |
| `dc990a5` (local drain, no fix) | 1 of 404 | 7 of 201 |
| fix | 0 of 6 692 | 0 of 3 345 |

The `5309d38` thread_storm figure and the fix's figures come from campaign-043
(15.1 lane-hours). It ran the old thread_storm alongside the fixed binaries,
five lanes for three hours. Of the 525 bad runs, 445 crashed or failed and
80 hung. The fix's six `stw_mt` timeouts all have the upstream shape: two
threads at `parallel/scheduler.cr:97`, no collector frame and no STW report
(crystal-lang/crystal#17486). The `5309d38` `stw_mt` 17 include 4 hangs that
were not classified. A release build of `stw_mt` with the fix and a
probe on the refusal branch (`PROBE late pop refused with work on the
stack`) ran 2 258 times. It had 0 failures, and in 3 runs a late pop found
work on the stack and was refused. Before the fix, each of those would have
been the race.

## macOS and Windows after the fix

`GCRY_PARALLEL_MARK=4`, `stw_mt` and `thread_storm` alternating for 60 minutes
per runner, each run bounded by `bench/run_bounded.sh` (probe
`probe-pmstress`):

| runner | runs | failed | stalled |
|---|---:|---:|---:|
| macos-latest | 1 100 | 0 | 4, all classified upstream by `sample` |
| macos-15-intel | 1 226 | 0 | 0 |
| windows-latest | 1 566 | 0 | 4 (`stw_mt`; no debugger to classify) |
| windows-11-arm, native | 1 758 | 0 | 1 (`stw_mt`) |

The Windows stalls were then captured with `cdb` against a `--debug` build
(probe `probe-winstall`, `stw_mt` alone for 70 minutes per job). With 4
workers, 3 of 3 762 runs hung; serial, 1 of 2 051. In every capture the main
thread is in the Parallel scheduler's `find_next_runnable` → `yield` →
`yield_current`, the other schedulers wait on IOCP, the mark helpers sleep in
`mark_worker_loop`, and no thread has a collector frame. That is Windows'
shape of crystal-lang/crystal#17486, and parallel mark does not change its rate.

