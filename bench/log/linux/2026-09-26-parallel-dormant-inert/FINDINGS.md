# `GCRY_PARALLEL_DORMANT=1` was inert on Linux for two months

**Date:** 2026-09-26 · host: QEMU x86_64, 12 vCPU (desktop session loading it;
RSS is not timing-sensitive) · Kemal `/json`, `wrk -t4 -c100 -d6s`, then two
`GC.collect`s, post-GC RSS and `/gc-stats`.

## Found

Chasing why one extra thread costs an EC1 program +63% RSS
(`../2026-09-26-ec1-extra-thread/`): past the multi-mutator boundary empty
chunks stay mapped, even across an explicit `GC.collect`. The documented
remedy for that is `GCRY_PARALLEL_DORMANT=1` (docs/POLICY.md, "RSS stretch").
It did nothing. Neither did `GCRY_PARALLEL_DORMANT_ALL=1`.

## Why

The dormant path releases empties *within* `empty_chunk_retain`
(`2687c51`, 2026-08-01, "bound Parallel empty-chunk dormant to
empty_chunk_retain", measured then at a 32 MiB budget). Two days later
`9228bb9` set the Linux process default for that budget to 0, for EC1 RSS.
From then on `can_dormant` was false for every chunk. `_ALL`'s arm also
requires `empty_chunk_retain > 0`. Darwin's default is 512 KiB, which left
the opt-in nearly inert there. No gate ran either knob.

## Measured (`before_probe.py`, then `after_probe.py` on the fixed build)

| shape | default | `DORMANT=1` before | `DORMANT=1` after | `DORMANT=1` + `RETAIN=0` after (red arm) |
|---|---:|---:|---:|---:|
| EC4 | 83.8 MB | 83.4 MB (0 MB dormant) | **19.7 MB** (65 MB dormant) | 83.3 MB |
| EC1 + one parked thread | 25.1 MB | 24.9 MB | **15.6 MB** (9 MB dormant) | 24.9 MB |

Before the fix, `GCRY_EMPTY_CHUNK_RETAIN=64M` alongside the knob gave the same
19.3 / 15.3 MB, which is what located the cause.

## Fix

Setting either dormant knob without `GCRY_EMPTY_CHUNK_RETAIN` now gives the
dormant path a budget of one Parallel threshold (64 MiB). An explicit
`GCRY_EMPTY_CHUNK_RETAIN` still wins, so `=0` reproduces the old behaviour.
That is the red arm of the new gate, `make parallel-dormant`. The gate is
multi-mutator by construction (two parked threads); a 64 MiB burst is dropped
and collected twice. Default: 54 MB RSS, 44 MB of empties kept mapped. With
the knob: 12 MB, 44 MB dormant. With the knob and a zero budget: 53 MB, 0
dormant, and the gate requires that. With the fix reverted by hand,
`--expect-dormant` fails. In CI on Linux and macOS.

## Not measured

Throughput with the opt-in (2026-08-01: "~75% `/json` at ~1.7× Boehm" at
EC4). It stays opt-in; nothing about the default changed.

## The paired cost, and macOS (same day, later)

`bench/sound_matrix.py --profile dormant:GCRY_PARALLEL_DORMANT=1`, 10 rounds
on the CI runners (run `36266146696`, `dormant-matrix-*.json`), knob ÷ tuned:

| shape | Linux req/s | Linux pause | Linux RSS | macOS req/s | macOS RSS |
|---|---|---:|---:|---|---:|
| EC1 | 1.064 | 0.99× | 1.03× | 0.981 | **1.69×** |
| EC1 + one thread | 1.010 | 0.98× | **0.49×** | 0.882 | 0.99× |
| EC4 | 1.021 | 1.01× | **0.25×** | 1.075 | 1.05× |

On Linux the opt-in now costs nothing measurable and takes three quarters off
the post-GC RSS at EC4. That is not what August measured (thr ~4% lower,
before the bitmap allocator and today's fixes). On macOS it bought nothing
and cost +69% at EC1, because release there is `MADV_FREE` (see the ROADMAP
page-release item). The 64 MiB budget turned empties the EC1 path would have
munmapped into dormant ones that stayed resident. So the budget raise is
Linux-only (`ecb4bc4`), and on Darwin `make parallel-dormant` reports without
asserting.

## The worst case for the budget: tree churn at EC4 (2026-09-27)

Kemal barely touches the chunks the opt-in releases. A binary-trees churn does
the opposite: every cycle empties chunks and needs them straight back, so
every revival faults its pages in again. `probe/mt_trees.cr` runs four
workers, each building and dropping depth-16 trees with a long-lived tree
kept per worker. `probe/paired.py` runs 12 rounds, each executing off, on
and a second off in rotated order. Measured on the local host with nothing
else running, `--release`, code at `16c1f72`:

| shape | on/off time | off2/off (null) | post-GC RSS on/off | peak RSS on/off |
|---|---|---|---:|---:|
| depth 16 × 40 | 1.013 (0.951–1.099) | 1.007 (0.926–1.101) | **0.26×** | 0.93× |
| depth 14 × 160 | 1.006 (0.955–1.052) | 1.004 (0.929–1.045) | **0.41×** | 0.94× |

The time cost is inside what the null arm moves: 35.2 → 8.9 MB and
15.6 → 6.4 MB after `GC.collect`, for no measurable time.

## Under high concurrency it does cost throughput: it stays opt-in

The soft-soak shape is heavier than the matrix: EC4 Kemal, `wrk -c100 -d8
/json`. `make soft-soak-ec4` with the knob on passes 40/40 (soft 0, hard 0),
but its median was 235k req/s against 280k for the control run after it. The
two runs were sequential, so that says nothing by itself.

Paired on that shape (`paired_kemal.py`, 16 rounds, off / on / off2 rotated,
same binary `bin/kemal-gcry-soft-soak`, local host otherwise idle):

| arm | median req/s | RSS at the end of the load |
|---|---:|---:|
| off | 269 421 | 84.8 MB |
| on | 240 522 | **53.8 MB** |
| off2 (null) | 274 953 | 84.7 MB |

- on/off: **0.914** (0.738–1.128). The null off2/off is 1.058 (0.810–1.323).
- The on arm was below off in 15 of 16 rounds and below off2 in 15 of 16
  (sign test p ≈ 0.0003).
- A 10-round run before it gave on/off 0.825 with null 1.065.

So at this concurrency the opt-in costs about a tenth of the throughput, for
about a third off the RSS under load. The CI matrix (1.02×) ran a lighter
load and did not see it. This matches the old note beside the flag, "thr
~25%", in direction if not size. It stays opt-in, as documented: an RSS
lever for programs that want it.

## macOS: `MADV_FREE_REUSABLE` (2026-09-27, `d180b88`)

Dormant chunks and the large cache now release with `MADV_FREE_REUSABLE`, and
both revivals and the large-cache hand-out call `MADV_FREE_REUSE` first.
`make parallel-dormant` on the macOS runner (run `36325589830`), 64 MiB
budget:

| release | dormant | footprint peak → after `GC.collect` | `ps` RSS after |
|---|---:|---:|---:|
| `MADV_FREE_REUSABLE` | 43 MB | 60 → **11 MB** | 53 MB |
| `MADV_FREE` (`GCRY_DARWIN_REUSABLE=0`) | 44 MB | 61 → 51 MB | 53 MB |

`ps` RSS counts reusable pages until the kernel takes them, so on macOS the
footprint is the number to read. The gate asserts both arms: at least half
the dormant bytes leave the footprint with the default release, and fewer
than half with `MADV_FREE`.

### The budget on macOS, with the reusable release

`bench/sound_matrix.py --profile dormant64:GCRY_PARALLEL_DORMANT=1,GCRY_EMPTY_CHUNK_RETAIN=67108864`,
10 rounds on the CI runners (run `36327145095`, `dormant64-matrix-*.json`),
knob ÷ tuned. macOS now reports the footprint beside `ps` RSS:

| shape | macOS req/s | macOS `ps` RSS | macOS footprint | Linux req/s | Linux RSS |
|---|---|---:|---:|---|---:|
| EC1 | 0.986 | 1.65× | **1.04×** | 0.985 | 1.04× |
| EC1 + one thread | 0.996 | 0.99× | **0.50×** | 1.020 | 0.49× |
| EC4 | 0.894 (0.547–1.523) | 1.02× | **0.36×** | 0.970 | 0.25× |

The +69% at EC1 that kept the budget Linux-only was `ps` RSS, which counts
reusable pages. The footprint shows no such cost, and past the boundary it
now roughly halves or better, as on Linux. So the opt-in's budget applies on
Darwin too. The throughput cost at EC4 is the one measured on Linux under
heavy load (0.914× at `wrk -c100`), and it is why the knob stays opt-in on
both platforms.
