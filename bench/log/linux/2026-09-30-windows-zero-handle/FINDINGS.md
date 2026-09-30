# Windows: a starting thread could be listed with handle 0 (2026-09-30)

## Sighting

`make thread-birth-fiber` on `test (windows x86_64, default)`, master
`692d1fc`:

```
Unhandled exception: gcry: Windows thread suspension or context capture failed (Exception)
  from src\gcry\platform\windows_stw.cr:273 in 'raise_thread_suspension_error'
  from src\gcry\collect_stw.cr:805 in 'stop_world_quiescing_roots'
```

The message named neither the call nor the error. It now does (`7e6e362`).
A probe on the same build (probe run 36695202872, 25 runs of 3 000 births on
each runner) then failed once on windows-11-arm with:

```
gcry: Windows thread suspension or context capture failed: SuspendThread on thread handle 0x0, error 6
```

## Cause

Crystal's `Thread#init_handle` is `@system_handle = GC.beginthreadex(...)`. The
handle is stored after the call returns. gcry's `GC.beginthreadex` creates
the thread suspended, stages it, and resumes it before returning. The new
thread's `Thread#start` pushes it onto `Thread.threads` as soon as it runs.
So for a moment a listed thread has `@system_handle == 0`, and a stop in that
moment called `SuspendThread(0)`, which fails with `ERROR_INVALID_HANDLE` and
refuses the collection.

Linux and macOS are not affected: `pthread_create` writes the handle
through the pointer it is given before the new thread can run. On Linux,
2 000 births under a watcher reading 98.9 M list samples found 0 null
handles.

## Fix

`GC.beginthreadex` writes the handle into the `Thread` (its `arglist`)
before `ResumeThread`, and Crystal's own store afterwards writes the same
value (`eb9709f`). Separately, `7e6e362` makes a failed suspend name the
call, the handle and `GetLastError`. It also skips a listed thread that
has already exited, which has nothing left to scan. 0 such threads were
seen in 50 probe runs.

## Measured

A watcher thread walks the thread list continuously and counts entries with a
zero handle, while two threads start 1 500 threads, one at a time, against a
collector thread (probe runs 36696216329 and 36698009730). Pre is
`7e6e362` and post is `eb9709f`, built in the same job and interleaved:

| arm | runs | runs with a zero handle listed | zero-handle samples |
|---|---:|---:|---:|
| pre | 40 | 2 | 155 078, 26 |
| post | 40 | 0 | 0 |

The pre run with 155 078 samples also had one collection refused.

Both arms had runs that did not finish within 150 s: pre 3 of 40, post
4 of 40. The watchdog printed nothing. That hang belongs to the probe
program, not to this change; it is not understood and is not in any gate.
