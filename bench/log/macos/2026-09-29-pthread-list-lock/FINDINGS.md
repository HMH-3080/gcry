# macOS: the stop asked libpthread about threads while one held its list lock (2026-09-29)

## Sighting

`make thread-birth-fiber` is new today. It starts threads one at a time while
another thread collects back to back. On macos-latest it hung the `test
(darwin native)` job until the job was cancelled at 20 minutes (run
36609028337, `a30d80c`).

## Rate, and it predates today's changes

Probe on macos-latest, `bench/thread_birth_fiber.cr` 300 births, each run
bounded at 45 s by `bench/run_bounded.sh` with a `sample` capture. The runs
interleave two builds:

| build | runs | stalled |
|---|---:|---:|
| `3432a9b` (before the page-size change) | 25 | 13 |
| `a30d80c` | 25 | 11 |

24 of 50. The page-size change is not the cause.

## The stall

`sample`, every stalled run the same:

```
main       __crystal_main → Thread.new → init_handle → GC.pthread_create
           → _pthread_create + 924                               (suspended)
collector  GC.collect → run_collection_body → stop_world
           → Platform.stop_world_threads (darwin_stw.cr)
           → pthread_mach_thread_np → _os_unfair_lock_lock_slow → __ulock_wait2
SYSMON     MonitorGate.enter (spinning, world stopped)
```

`pthread_mach_thread_np` validates a foreign `pthread_t` under libpthread's
global `_pthread_list_lock`. `pthread_get_stackaddr_np` /
`pthread_get_stacksize_np` do the same for a thread other than the caller.
`_pthread_create` holds that lock while it links the new thread in. The stop
walked Crystal's thread list and, for each thread in turn, asked for its port
and then suspended it. Once main was suspended inside `_pthread_create`, the
next thread's port lookup waited for a lock whose owner could not run. The
resume asked the same function about every thread while the rest were still
suspended, so it could hang the same way. So could the stack-bounds lookups
the scan makes during the stop.

This is the Darwin form of the Linux hang that moved `pthread_getattr_np` out
of the suspension window (`bench/stw_startup_hang.cr`).
`darwin_stack.cr` said Darwin's accessors "only read the descriptor: no lock".
They do not.

## Fix

`darwin_stw.cr`:

1. **Resolve, then suspend.** Every listed thread's Mach port and stack
   bounds go into a stop table while nothing is suspended. The table is libc
   `malloc`, grown before the first suspend. The suspends and the resume then
   use only the table.
2. **Resolve again when the list grew.** After the suspends, the thread list
   is re-read (Crystal objects only). If a thread is listed that the table
   lacks, everything is resumed and the round repeats, at most 8 times. The
   first version stopped at step 1. That left a thread born between the
   resolve and the last suspend neither suspended nor scanned, and it lost
   its own main fiber: `main fiber … is not an allocated block`, then
   `Thread#execution_context cannot be nil`, 12 of 25 runs (`9c19480`).
3. **Bounds during a stop come from the table.** A thread missing from it
   falls back to its main fiber's recorded stack, which is a Crystal object
   and needs no lock. `darwin_stack.cr` `snapshotted_stack_bounds`.

Counters: `Platform.stop_rounds_retried`, `stop_rounds_exhausted`, and
`stack_bounds_snapshot_misses` (on `/gc-stats` as `pthread_bounds_misses`).

## After (probe, `8bc3b35` = steps 1 and 2)

| check | result |
|---|---|
| `thread_birth_fiber` 300 births, 20 runs | 20 ok, 0 stalled |
| `make fiber-list-exit-race` | shipped 3/3 lost 0; unlocked 5/5 lost objects |
| `make darwin-stw-resume` | ok |

And `test (darwin native)` on master `8bc3b35`: green.

## The one poisoned-pointer SIGSEGV

The `8bc3b35` probe also ran `fiber_list_exit_race --child` directly 3 times,
and 1 died of a poisoned-pointer SIGSEGV (`GCRY_POISON_FREED`). Its three
shipped runs inside `make fiber-list-exit-race` were clean. `e69e36f` added
step 3. Paired against `3432a9b`, from before any of this, 15 children each,
interleaved (probe run 36622253889):

| build | runs | lost a holder or died |
|---|---:|---:|
| `3432a9b` | 15 | 0 |
| `e69e36f` | 15 | 0 |

Not seen again. [INFERENCE] Step 3 closed it: under step 2 alone, a thread
born after the last recheck had no bounds at all. Master CI on `e69e36f`:
all jobs green.

## The resolve-again rounds were a regression, and are gone (2026-09-30)

On `f3364ee` (the first 0.32.0 commit) `make fiber-list-exit-race` failed on
macOS CI: 1 of 3 shipped children died. Paired on macos-latest, 25 children
per arm on each of two runners (probe run 36706364101):

| build | children | died |
|---|---:|---:|
| `3432a9b` (before any change here) | 50 | 0 |
| `954d4e1` (table + resolve-again rounds + main-fiber fallback) | 50 | 2 |

Both deaths were poisoned-pointer faults on a freed `Fiber` still linked on
the fiber list: one in `Fiber.inactive` → `LinkedList#delete`, one in
`scan_all_fiber_roots`. This is also the "one poisoned-pointer SIGSEGV" of
the section above. 15 against 15 had not been enough runs to show it.

The root of it: this platform never held Crystal's thread-list mutex across a
stop, and Linux and Windows always have. So the list moved during the stop,
and step 2 answered that by resuming everything and resolving again. `131f626`
takes the mutex from before the resolve until after the resume, as the other
two platforms do. The list is then frozen, and steps 2 and 3 (the rounds and
the main-fiber fallback) were removed as dead code. [INFERENCE] The rounds
were the regression: they resumed and re-suspended every thread in the
middle of a stop, which no other platform does. Not isolated further;
removing them is what was measured.

Probe run 36707277643, `131f626` against `3432a9b`, two runners:

| check | result |
|---|---|
| exit race children | `3432a9b` 0 of 50, `131f626` 0 of 50 |
| `thread_birth_fiber` 300 births | 0 stalled in 20 |
| `make darwin-stw-resume`, `tls-roots`, `fiber-list-exit-race`, `thread-birth-fiber` | all ok |
