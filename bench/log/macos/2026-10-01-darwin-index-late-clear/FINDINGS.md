# Darwin read the chunk index unlocked after a resume

`Heap#chunk_containing` skips `@index_lock` while `@world_stopped` is set: only
the collector should be able to read the index then. On Linux, `start_world`
cleared the flag after resuming every thread until 2026-08-22, when the order
was fixed and `make stw-index-race` was written to keep it fixed. That gate ran
only on Linux. Darwin's branch of `start_world` still cleared the flag after
`Platform.start_world_threads`. Windows' branch already cleared it first.

## How it was found

A coverage probe on 2026-10-01 ran the Linux-only `make` gates once each on
macos-latest (probe run 36808891888). `stw-index-race` failed on its shipped
arm:

    default     unlocked reads: collector 125106, other threads 90 (last 0x16b357000)
    late-clear  unlocked reads: collector 127996, other threads 345 (last 0x16bacb000)
    FAIL: default: 90 unlocked chunk-index read(s) by a thread that is not the collector,
    while the world was stopped — the lock skip is unsound

## Fix

`collect_stw.cr`: the Darwin/Windows branch clears `@world_stopped` before
`start_world_threads`, unless `GCRY_STW_LATE_CLEAR=1` is set. Windows already
cleared it before the resume, but did so unconditionally, so the red arm did
nothing there: the 2026-10-01 Windows probe saw 0 foreign reads on both arms.

## After (probe run on `probe-sir`, 5 runs per runner)

| runner | shipped: foreign reads | late-clear: foreign reads |
|---|---|---|
| macos-latest (arm64) | 0, 0, 0, 0, 0 | 10, 16, 61, 96, 48 |
| macos-15-intel | 0, 0, 0, 0, 0 | 799, 1791, 48, 4853, 353 |
| windows-latest | 0, 0, 0, 0, 0 | 4351, 5143, 5678, 4201, 4149 |

The gate now runs in the macOS, Intel macOS and Windows CI jobs.

## Exposure

[INFERENCE] The window opens on every collection with more than one mutator
thread. It runs from the first `thread_resume` to the store that clears the
flag, a loop over the stopped threads. A read in that window is only a crash
if a peer inserts or removes a chunk at the same moment. Mutators reach
`chunk_containing` through `find_block`, which `GC.free`, `realloc` and the
TLAB fast path call. The header of `bench/stw_index_race.cr` records a Darwin
crash in `find_block` ← `tlab_alloc_small` that was never attributed. TLAB is
off by default, so the default build's rate is lower.
