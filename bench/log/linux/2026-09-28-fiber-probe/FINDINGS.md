# A syscall pair per parked fiber, per collection

**Date:** 2026-09-28 · QEMU x86_64, 12 vCPU · Crystal 1.21.0 · old = `607a8a1`.

## Found

With `GCRY_ROOT_PHASE_TIMING=1`, Kemal at EC1 under `wrk -c100` spends
170 µs of a 550 µs pause in roots. 141 µs of that is the fiber roots:
about 105 parked connection fibers, each scanned from its saved SP to the
stack's end.

Each range went through `Roots.scan_range(safe: true)`. That probes the
first page, and the last page too if it is a different one, by `write(2)`ing
a byte of it into a pipe and reading it back. `EFAULT` means the page is
unreadable. A parked Kemal fiber's live stack usually fits in one page, so
this costs one probe, two syscalls, per fiber.

## Measured, in steps

`probe_ab.py`: old, null (old again) and new run concurrently at EC1, each
under its own `wrk -t2 -c100 -d15s`, with the start order rotated. The
figures are medians of the per-collection trace. A stress campaign ran on
the host throughout.

| variant | roots, new − old | pause, new − old |
|---|---:|---:|
| no probe on any range starting above the guard (throwaway) | −32 µs, 9/9 | −27 µs, 9/9 |
| skip only the *last*-page probe | +1 µs, 3/9 | −4 µs, 6/9 |
| **shipped: no probe for a pooled stack above the guard's real page** | **−28 µs, 8/8** | **−22 µs, 8/8** |

Skipping only the last page saved nothing, because it was almost never
taken. The shipped rows exclude round 0, where stale servers left on the
old arm's ports by an aborted run answered the old and null arms, which
logged no collections. Over rounds 1–8 the pause was 549 µs old and
525 µs new, and null − old was +6 µs.

## Why it is safe

A fiber's stack is `reusable?` only when Crystal allocated it
(`Crystal::System::Fiber.allocate_stack`: one `mmap`, a guard page at the
low end, `munmap`ped whole). `Fiber#run` takes the fiber off the list
(`Fiber.inactive`) before it hands the stack back to the pool, and the pool
unmaps only stacks it holds. So a pooled stack still on the list is mapped
from its guard to its end.

What keeps the probe:
- a thread's main fiber, whose bounds come from glibc and can include a
  guard;
- any `top` inside the guard's page, measured in the kernel's page size.
  A 4 KiB `mprotect` on a 16 KiB-page macOS protects the whole 16 KiB, and
  the multi-mutator lag can put `top` there.

Windows keeps its `VirtualQuery` walk.

The first build read the kernel page size from a class variable with an
initializer. That is a Crystal `once`, and `GC.init` runs before there is a
fiber, so every process died at startup. `process_spec` caught it. The
variable is `uninitialized` now, read as `PAGE_SIZE` until `GC.init` sets
it.

Gates: `crystal spec` (both layouts), `process_spec`, `make
stw-mt-property-test-short`, `scheduler-roots`, `nested-spawn-uaf`,
`ec-queue-audit`, `stw-lag-pause`, `thread-storm-short`,
`pattern-fuzz-short` and `dead-stack-root`, plus the Darwin cross-compile
and `make windows-typecheck`.

## Tried after it, and not shipped

Both were measured at EC4 with the same A/B, 9 rounds, while a stress
campaign loaded the host.

- **One snapshot of the thread SPs per fiber walk.** `fiber_stack_sp_scan_low`
  asks every thread for its SP again for every fiber: a linear search of
  the STW slot table and a `"SYSMON"` string comparison per thread. Taking
  them once per walk saved **6 µs of roots, lower in 7/9**. The null arm
  moved 2 µs.
- **Try the thread's `current_fiber` before the fiber list** in
  `scan_stack_containing_sp`, which walks every fiber for every thread.
  This saved **2 µs of the stacks phase, 7/9**. `scan_all_fiber_roots` has
  just walked the same list, so it is warm and the walk is cheap.

Neither is worth its code. What is left in EC4's roots and stacks is
reading the stacks themselves.

The `fiber_scan_from_guard` count on `/gc-stats` is cumulative, not per
collection. Reading it as per-collection suggested 56 whole-stack scans a
collection. An instrumented build found about one, SYSMON's main fiber, as
documented.
