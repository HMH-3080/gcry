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
