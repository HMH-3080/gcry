# A spawned thread's `@[ThreadLocal]`: a root on Linux only

**Date:** 2026-09-29 · probe run `36601338951` on four runners.

`make tls-roots` covers the main thread's thread-locals.
`bench/thread_tls_roots.cr` asks the same of a spawned thread: its only
reference to an atomic block sits in a `@[ThreadLocal]`, main collects three
times, and the block must survive. A control arm holds it nowhere, and there
the block must die.

| runner | held, survived | control, died |
|---|---:|---:|
| ubuntu-latest (x86_64) | 5 / 5 | 2 / 2 |
| ubuntu-24.04-arm (aarch64) | 5 / 5 | 2 / 2 |
| macos-latest | **0 / 5** | 2 / 2 |
| windows-latest | **0 / 5** | 2 / 2 |

On Linux, glibc places a spawned thread's TLS block at the top of its stack
mapping, which the pthread-stack scan already reads. Darwin's TLV allocates
the block with `malloc`, and Windows keeps it where the TEB points. gcry
scans neither.

This is not treated as a defect. Crystal documents `@[ThreadLocal]` as
unreachable by the GC. `Object.thread_local` (`object.cr`) keeps every value
on the `Thread` object too, "whose lifetime outlives the actual thread",
precisely so the collector can find it. The stdlib's raw thread-locals are
`@@current_thread : Thread?` values, which the thread list roots anyway.
Boehm does not scan them there either. Code that keeps the only reference
to a heap object in a raw `@[ThreadLocal]` breaks that contract on every GC.

`make thread-tls-roots` runs on Linux CI so that the coverage Linux does
have cannot regress unnoticed. Covering macOS and Windows would take
per-thread TLV/TEB enumeration inside the stop. That is recorded as a
possible improvement, not an open bug.
