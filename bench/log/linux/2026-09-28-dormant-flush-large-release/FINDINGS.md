# A large chunk released with its block still allocated — two sightings, not reproduced

**Date:** 2026-09-28 · QEMU x86_64, 12 vCPU · Crystal 1.21.0.

## Sightings

In the default-configuration campaign on `2a46123` (`campaign-summary.md`,
1532 runs over 10 lane-hours), `dormant_flush` failed 3 of 139. Every other
lane passed every run.

- **Seeds 20012 and 20013**, consecutive and in the campaign's first five
  minutes. The queued (shipped) arm faulted:

  ```
  gcry: SIGSEGV at 0x7f96fa236024 — in a chunk gcry RELEASED — base 0x7f96fa236000,
  45056 bytes, large-object release, at collection 120; the write is 36 bytes into it.
  Collections since: 0. First user word at release: 0x90000a000 (type_id 40960).
  Blocks still allocated at release: 1
  ```

  A worker wrote into its own 40 960-byte buffer after the chunk under it
  had been released, and at the release the block's header still said
  *allocated*. In 20013, the scheduled arms (the ones that force the
  interleaving) also misbehaved: "queued walk failed" with no reason, and
  "immediate walk did not fault". That fits a host under unusual load at
  that moment.
- **Seed 20060** was a child killed on the deadline, not a fault. The harness
  says so itself.

## Not reproduced

`df_ab.py` ran the binary from before release-on-collect (`db50034`) next to
this one: 6 copies of each at once, 5 rounds, 12 processes on 12 vCPU.
Both were **0 of 30**. Earlier campaigns ran the same lane 152 times
(`db50034`) and 192 times (`a7debe4`) without a failure. For this headerless
harness, `a7debe4` and `2a46123` differ in no line of `src/`.

So nothing ties the sighting to this week's changes. Nothing clears them
either: two faults in a row, then none in 197 runs, looks like a
host-condition window rather than a rate.

## What the report rules in and out

- Allocation from the cache (`take_large_free`) and the trim's detach both
  run under `@alloc_lock`. A block handed out cannot then be detached by
  that trim.
- A USED header on a detached chunk therefore means one of two things:
  - the chunk was on a bucket list twice, taken once and trimmed the
    second time (`@large_taken_used` / `@large_cached_twice` would count
    it, but the child died before printing them); or
  - it was written USED after it was detached, and nothing on the
    allocation path does that.
- The large sweep does not read `release_empty_chunks_this_collect?`, so
  release-on-collect does not reach it.

Open in the ROADMAP. The next sighting should run with `GCRY_TRACE_LARGE=1`,
which ties the release to its allocation.

## A lane of nothing else

`run-df.py`: five lanes, all `dormant_flush`, same binary, 90 minutes
(`df-only-results.tsv`). It ran **339 runs (2 034 children) with 0 faults**.
Two runs failed on a child killed at its deadline (seeds 20216 and 20297,
`dormant_flush-20216-4.log`). The STW watchdog (5 s) printed nothing, so the
hang was not inside a stop. That is about 0.1% of children. The earlier
campaigns had none in 344 runs and one in the campaign above. Recorded, not
chased: the harness captures no stacks for a killed child.

So the fault stays at two sightings, both in the first minutes of one
campaign.

## The hang, captured: an overflow raised under a class lock (fixed)

`DORMANT_FLUSH_CAPTURE` (`a4158b8`) keeps a hung child's thread states and gdb
backtraces. The relaunched campaign caught one within 95 runs
(`hang-capture-overflow.txt`):

- all five mutator threads spin on a size class's freelist lock in
  `alloc_old_small`;
- the collector waits for one in the lazy sweep;
- one worker is inside `raise`:

```
alloc_old_small ← allocate ← Array.new ← CallStack.unwind ← raise
  ← __crystal_raise_overflow ← bitmap_revive_dormant (bitmap_alloc.cr:999)
  ← bitmap_take_pool_chunk ← bitmap_refill_pool ← bitmap_alloc_locked
  ← alloc_old_small_locked (class lock held) ← … ← trim_large_cache ← GC.free
```

Line 999 was `@dormant_chunk_bytes -= mapped if @dormant_chunk_bytes >= mapped`.
Revivers under different class locks write that counter, and so does the
lazy sweep, which zeroes and recounts it with mutators running. So the
check can pass and the subtraction then underflow. The `OverflowError`'s
call stack needs an allocation, and that allocation needs the lock the
raising thread holds.

Release-on-collect made this reachable by default: multi-threaded programs
now have dormant chunks after every `GC.collect`, where before they had them
only with the opt-in.

The fix is `Heap#sat_sub`. It reads the counter once, stops at zero, and
cannot raise. Every `x -= n if x >= n` on a shared byte counter uses it (11
sites). A lost update skews a statistic that the next major recounts; a raise
under the lock had deadlocked the heap.
