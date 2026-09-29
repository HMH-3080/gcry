# Windows: a starting thread's main fiber was swept (2026-09-29)

## Sighting

CI run 36601599032 on `1bd689d` (no `src/` change), `test (windows x86_64,
default)`, the `make tls-roots` step:

```
Invalid memory access (C0000005) at address 0x2cc7cc900e0
[...] running? at src/fiber.cr:219
[...] scan_all_fiber_roots at src/gcry/collect_scan.cr:1376
[...] run_collection_body at src/gcry/collect.cr:2527
[...] collect:release_warm at src/gcry/collect.cr:1799
```

The fiber walk read a `Fiber` on a decommitted page: the fiber list held a
block the heap had freed and released.

## Reproduction (probe branch, windows-latest)

`bench/tls_roots.cr` in a loop, stdout to the runner pipe:

| arm | runs | C0000005 |
|---|---:|---:|
| shipped (fiber list held across the stop) | 100 | 3 |
| `GCRY_FIBER_LIST_UNLOCKED=1` | 100 | 0 |

All three faults carry the same stack and an address 0xe0 into a 64 KiB
allocation granule. With stdout redirected to a file: 0 in 200 (100 per arm).
3 against 0 does not separate the arms (Fisher p ≈ 0.25); [INFERENCE] a
thread blocked on the held fiber-list lock after allocating its fiber stays
in the window for the whole stop, which would widen it.

## Cause

`Thread#start` (Crystal 1.21, `src/crystal/system/thread.cr`):

```
Thread.threads.push(self)                              # listed: stop_world suspends it
Thread.current = self
@current_fiber = @main_fiber = fiber = Fiber.new(stack_address, self)
```

`Fiber#initialize(stack, thread)` allocates the fiber, and its last statement
is `Fiber.fibers.push(self)`. Every tls-roots process has such a thread:
`Crystal::EventLoop::IOCP.start_forwarder_thread` runs from `kernel.cr` at
startup, so the "IOCP" thread is starting while `__crystal_main` collects.

On Windows `Platform.pthread_stack_bounds(handle)` answered from
`thread.@main_fiber`, so it answered nil for a listed thread without one, and
`scan_pthread_stack` returns on nil bounds. Such a thread was suspended, its
registers scanned and its stack not. The new `Fiber` was on that stack and
nowhere else — not yet on the fiber list — so the sweep freed it. The push
then put the freed block on the list and a later walk read it.

Linux (`pthread_getattr_np` snapshot) and macOS (`pthread_get_stackaddr_np`)
ask the OS for every listed thread and are not affected.

## Fix

A listed thread without a main fiber is bounded by the OS instead: the
reservation holding the SP captured at suspend, `[AllocationBase, top)`,
where top is found by walking `VirtualQuery` regions up while the allocation
base is unchanged (the committed stack is reported as several regions). This is
`Platform.unborn_stack_bounds` in `src/gcry/platform/windows_stack.cr`, with a
lifetime counter `Platform.unborn_stack_bounds_total`.

## Gate: `bench/thread_birth_fiber.cr`, `make thread-birth-fiber`

One thread collects back to back; main starts threads one at a time. Each new
thread collects once itself, then checks that its main fiber is an allocated
block (`heap.live?`) whose stack bottom is its own OS stack top.

Paired on windows-latest, run 36605635714: pre-fix and post-fix binaries built
in one job from the same tree (pre-fix = `windows_stack.cr` from master), run
interleaved, 10 runs of 300 births each:

| arm | runs failed | fibers freed | threads bounded by the new path |
|---|---:|---:|---:|
| pre-fix | 6 / 10 | 9 of 3 000 | — |
| post-fix | 0 / 10 | 0 of 3 000 | 57 |

The same job, `tls_roots` interleaved 150 × 2 (output discarded): pre 1
failure, post 0.

Windows CI runs the gate at 3 000 births (~8 s); a pre-fix binary lost 9 in
that many. Linux and macOS run it at the default 300 births as a
no-regression gate. On the local Linux host: 300 births, 5 142 concurrent
collections, 0 freed.
