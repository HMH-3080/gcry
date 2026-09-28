# Restart the world in one batch, not one thread at a time

**Date:** 2026-09-28 · QEMU x86_64, 12 vCPU · Crystal 1.21.0 · old = `f0749ba`.

## What it was

`stop_world` sends every suspend signal first and then waits for the
acknowledgements, so a stop costs roughly the slowest thread. On Linux,
`start_world` did not do the same. It resumed one thread, spun until that
thread cleared its acknowledgement, and only then resumed the next. A
restart therefore cost the *sum* of every thread's wake-up: a futex wake
and a context switch each, plus, on a busy host, a wait in the run queue.

The per-collection trace of Kemal at EC4 under `wrk -c100` put the restart
among the largest parts of a pause. At the medians it was 216 µs on a
lightly loaded run. Its mean was 1.48 ms, from a long tail.

## Change

Linux `start_world` sends every resume, then waits for each
acknowledgement, with the same re-send after 10 000 spins as before. Each
thread acknowledges in its own slot, so no wake depends on another. The
wait itself stays, because the next stop must not find a thread still
inside the previous stop's handler. macOS and Windows resume with
synchronous `thread_resume` / `ResumeThread` and are unchanged.

## Measured

`resume_ab.py`: three Kemal servers at `EC_PARALLELISM=4` run concurrently,
old, null (old again) and new, each under its own `wrk -t2 -c100 -d15s`,
with the start order rotated each round. The figures are medians over the
collections under load, from `GCRY_TRACE`. A 5-lane stress campaign was
running on the host, so it was heavily oversubscribed (pauses of about 6 ms).
9 rounds:

| paired difference | `stw_start` | pause |
|---|---:|---:|
| null − old | −348 µs, lower in 5/9 | −290 µs, lower in 5/9 |
| new − old | **−1 408 µs, lower in 8/9** | **−1 518 µs, lower in 7/9** |

Throughput did not move (old 78 439, null 79 754, new 79 694 req/s).

`micro.cr`, a synthetic worst case: 8 threads spinning on 12 vCPU, with both
binaries running at once, so 18 runnable threads. Over 300 `GC.collect`s,
three runs each, the `stw_start` p50 was 16.7 / 20.3 / 20.6 ms old against
6.8 / 11.6 / 8.7 ms new.

Gates: `crystal spec`, `process_spec`, `make stw-epoch`, `stw-ack-window`,
`stw-watchdog`, `stw-monitor-gate`, `stw-startup-hang`,
`stw-mt-property-test-short` and `thread-storm-short`.
