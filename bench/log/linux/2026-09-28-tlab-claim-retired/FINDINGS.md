# The marker's TLAB "on-stack freelist" claim, retired

**Date:** 2026-09-28 · QEMU x86_64, 12 vCPU · Crystal 1.21.0 · old = `aea94a0`.

## What it was

On a TLAB heap, a stack or thread root that pointed at a FREE block made
`mark_impl` claim it. The claim cleared FREE and marked the block's
`next_free` chain. It assumed a mutator could be stopped holding FREE nodes
out of its TLAB, and that a chunk made only of such nodes would look empty
and be released under it.

That stopped being possible on 2026-09-27
(`../2026-09-27-dormant-revive-race/`):

- The collector takes every TLAB slot lock before it stops the world
  (`lock_tlab_slots_for_stop`). No thread is stopped between reading its
  head block and storing the new head.
- A refill that a stop overtakes, with its batch off the class list but not
  yet installed, throws the batch away by epoch (`tlab_refill_once`). It
  writes nothing into those blocks after the stop.

So the claim protected nothing. It only turned stale FREE words on stacks
into USED blocks, which then sat on class freelists that the allocator
has to skip. Earlier it had also been found corrupting old freelists during
a minor, and was skipped there (`make nursery-tlab-smoke`,
`GCRY_TLAB_MINOR_FREE_OLD`).

## Change

- `mark_impl_unlocked` returns on a block that `block_allocated?` says nobody
  holds, whatever the root source.
- `claim_free_tlab_block` and the `GCRY_TLAB_MINOR_FREE_OLD` research knob
  are gone.
- `make nursery-tlab-smoke` keeps a FREE node on the stack through a minor
  **and a major**, and requires it to stay FREE in both.
  - On the old tree the major probe fails ("a major claimed a FREE node on
    the stack").
  - Putting the old minor behaviour back fails the minor probe too. Both
    were run.

## Retention

`retention.cr`, headered, TLAB on, `GCRY_BITMAP_ALLOC=0`. Each of 40 rounds
allocates 20 000 small objects, frees 256 of them with `GC.free` while
keeping each freed address in a stack array, drops the rest, and collects.
Old and new ran concurrently, 3 runs each, and every run gave the same
numbers:

| | heap after the last collect | `free_bytes` | live strings intact |
|---|---:|---:|---:|
| old (claim) | 3 903 488 | 3 997 760 | yes |
| new | **2 068 480** | 1 399 056 | yes |

Under the claim, the heap kept **1.9×** the memory. `free_bytes` even
exceeded the heap size, because the claim flips blocks the free-byte
accounting had already counted as free. This workload is adversarial: 256
stale FREE pointers held on the stack for a whole collection. Ordinary code
holds fewer.

## Stress

`stress.py`: `stw_mt_property_test_hdr`, seeds 1–30, `--iterations=200
--workers=2,4`, in four configurations: `--tlab`, `--tlab --nursery`, and
each again with `GCRY_PARALLEL_DORMANT=1`, with poison and a watchdog on two
of the four. Three lanes per binary, both binaries at once, beside a
5-lane campaign.

| | runs | failed | mean |
|---|---:|---:|---:|
| old | 120 | 0 | 7.9 s |
| new | 120 | 0 | 8.1 s |

Gates on the new tree: `crystal spec` (both layouts), `process_spec`,
`make stw-mt-property-test-short`, `chunk-search-race`, `parallel-dormant`,
`nursery-bitmap-marks` and `nursery-tlab-smoke`.

TLAB stays unsupported. This removes a cost from it; it does not make it
supported.
