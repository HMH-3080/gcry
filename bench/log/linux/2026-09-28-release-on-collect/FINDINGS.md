# `GC.collect` and the idle collector give a multi-mutator heap's empty chunks back

**Date:** 2026-09-28 · host: QEMU x86_64, 12 vCPU · Crystal 1.21.0 `--release`
· Kemal `/json`.

## The gap

Three collections ask for memory back: `GC.collect`, the idle collection after
two minutes without an allocation, and the emergency collection before an
`OutOfMemoryError`. All three pass `release_warm: true`.

On a single-mutator heap that unmaps every empty chunk. On a multi-mutator
heap, `release_empty_chunks_this_collect?` returned false unless the dormant
opt-in was set, so all three kept every empty chunk mapped. Kemal EC4 read
84 MB after `GC.collect` against 21 MB with the opt-in. A server that went
idle after a burst kept that RSS for good. The idle collector ran, but it
could not release anything.

The opt-in is not the answer as a default, because it makes empties dormant
at **every** major: at `wrk -c100` EC4 it costs about 9% of throughput
(`../2026-09-26-parallel-dormant-inert/`).

## The change

Those three collections now make every empty chunk dormant on a
multi-mutator heap, with no budget, as the single-mutator path unmaps them.
Ordinary majors are unchanged, so steady-state throughput is unchanged.
`GCRY_PARALLEL_RELEASE_ON_COLLECT=0` keeps the empties mapped.

Dormancy (`MADV_DONTNEED` on Linux, `MADV_FREE_REUSABLE` on Darwin) keeps the
chunk in the index. The next burst revives it with page faults rather than a
`mmap`, and the multi-mutator path already supports it (the opt-in). Two
campaigns with the opt-in on in every lane found no defect on the default
allocator (`../2026-09-27-dormant-revive-race/`).

## Results

`bench/sound_matrix.py --profile keep:GCRY_PARALLEL_RELEASE_ON_COLLECT=0`,
2 rounds locally. RSS is read after `/gc-collect`:

| shape | default | keep |
|---|---:|---:|
| EC1 | 16.0 MB | 16.0 MB |
| EC1 + one extra thread | **16.6 MB** | 31.6 MB |
| EC4 | **20.1 MB** | 84.9 MB |

EC1 with one extra thread now lands where a plain EC1 program does. That was
the RSS half of the ROADMAP item "One extra thread costs an EC1 program".

Idle, with no `GC.collect` (`idle_ec4.py`, EC4, `GCRY_IDLE_RELEASE_MS=2000`):

| arm | RSS after load | after 6 s idle |
|---|---:|---:|
| default | 83 MB | **18 MB** |
| keep | 83 MB | 82 MB |

`make parallel-dormant` now has both halves:

- The opt-in arms collect with an ordinary major (`--ordinary`), so they
  still show the opt-in's own effect.
- The default `GC.collect` arm must go dormant: 54 → 12 MB.
- Its red arm, `GCRY_PARALLEL_RELEASE_ON_COLLECT=0`, must stay inert: 54 MB.

## Soundness

Local gates, all green: `stw-mt-property-test-short`, `dormant-flush-race`,
`chunk-search-race`, `large-cache-race`, `thread-churn-uaf`,
`nested-spawn-uaf`, `idle-thread-roots`, `occupied-release`,
`scheduler-roots`.

Campaign lanes in the default configuration, built from `a7debe4` (the
`stw_mt` lanes collect through `GC.collect`, so every one of their
collections takes the new path): PENDING.
