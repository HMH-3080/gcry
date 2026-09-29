# `tls-roots` measured the type-id gate, and passed on a stale stack word

**Date:** 2026-09-29 · Linux locally, `windows x86_64, default` CI runner.

`make tls-roots` (and its Windows step) asks one question: is a block held
only in a main-thread `@[ThreadLocal]` a root?

## The Windows failures

The `windows x86_64, default` job died in that step on two of the four push
runs after `faf4c4d`. Both times it printed `Invalid memory access
(C0000005)` and then hung until the job was cancelled. A branch that runs
the step in a loop on that runner showed plain harness failures as well:
the slot was printed inside gcry's TLS root range, then `live?=false`.

| arm | failed |
|---|---:|
| fiber list held | 6 / 100 |
| `GCRY_FIBER_LIST_UNLOCKED=1` | 7 / 40 |

The lock was not the cause.

## Why

The TLS range is pushed into the static root ranges, and static roots go
through the type-id gate. The gate rejects a non-atomic block whose first
`Int32` is `<= 0` or `> 1 000 000`. The victim was a `GC.malloc` buffer
filled with `0xa5`, which is always rejected. With `GCRY_LIVE_ATTR=1` on
Linux:

| run | static rejects | static bytes | stack objects | victim |
|---|---:|---:|---:|---|
| default | 1 | 1 792 | 14 | alive |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | 0 | 1 888 (+96, the victim) | 13 | alive |
| `GCRY_TLS_ROOTS=0` | 0 | 1 792 | 9 | freed |

So in the default run the TLS scan rejected the victim, and an extra stack
root kept it: a copy `wipe_stack` had missed. On Windows that copy was
sometimes gone.

## Fix

The victim is `GC.malloc_atomic`. An atomic block passes the gate, so the
arm measures TLS coverage and nothing else.

| arm | Linux, 3 runs | Windows runner, 100 runs |
|---|---|---|
| held | alive, 0 static rejects, static bytes +96 | **100 ok** |
| `GCRY_TLS_ROOTS=0` | freed | **100 red, as it must be** |

## What it says about the gate

This is not new. `docs/SOUND-DEFAULTS.md` lists the static-root type-id gate
as a heuristic applied to real references, counted in
`type_id_root_false_negatives` and turned off by `GCRY_SOUND=1`. The gate
does drop real references. A class variable or thread-local that holds the
only pointer to a non-atomic raw buffer (a `Pointer(T).malloc` of
references, say) is kept only while the buffer's first `Int32` looks like a
type id. Whether the default should stay is the same policy question as the
rest of that document. This change does not take it up.
