# The dormant opt-in's first stress campaign: what it found in the header allocator

2026-09-26/27, Linux x86_64 (QEMU, 12 vCPU), Crystal 1.21.0.

`GCRY_PARALLEL_DORMANT=1` had done nothing on Linux since 0.18.0 (its budget
was 0; `bench/log/linux/2026-09-26-parallel-dormant-inert/`). Once it had a
budget, the code behind it ran for the first time in two months. So a 2 h
campaign ran every lane with the knob on (`run-dormant.py`, 5 lanes, the
same lanes as the 2026-09-26 sound campaign plus `dormant_flush`).

All three defects below need the **header** allocator
(`-Dgcry_block_headers`, `GCRY_BITMAP_ALLOC=0`) and dormant chunks. The
default bitmap allocator was clean in every lane.

## 1. A self-deadlock in the TLAB refill (fixed in `04cb670`)

The first hour hung every run of the two headered TLAB lanes, 36 of 36
(`campaign-summary.md`, `stall-self-deadlock.log`):

```
stw-mt-2-1  lock ← revive_dormant_chunk ← refill_size_class ← tlab_refill_once
stw-mt-2-0  lock ← current_tlab ← tlab_alloc_small
gc-idle     lock ← flush_pending_large_release ← run_collection_body
```

`tlab_refill_once` holds `@alloc_lock` for the whole refill.
`revive_dormant_chunk` took it again to order itself against the post-STW
dormant flush, a check added in 0.24.1 (`31c6dcf`). The lock is a spin lock
and not reentrant, so the reviver spun on itself. Everything else that needed
the lock spun behind it.

- 100 iterations of `stw_mt_property_test_hdr --tlab` with the knob hang 3 of
  3 seeds on the old code and pass on the fix.
- The fix: `refill_size_class(alloc_held:)` tells the revival that its caller
  holds the lock.
- Both CI TLAB steps now run a dormant arm under a timeout.
- `make stw-mt-property-test-short` runs the arm under `perl -e alarm`,
  because macOS has no `timeout` (`e13eb55`).

The binaries were swapped at 20:16:43 UTC. After that the two lanes ran 158
times with **0 hangs** and one timeout (seed 20087, 300 s; not captured).

## 2. Revival cleared the DORMANT flag before installing the freelist (fixed in `3106e72`)

With the hang gone, `stw_mt_hdr_tlab` failed a different way, 4 of 79 runs:

```
ERROR: after collect #156: root 8 cookie broken
```

A root object's cookie was overwritten with zeros (`cookie-20043.log`). The
header revival did three things:

1. flip DORMANT off;
2. rewrite every block header;
3. install the chain on the class list.

A thread suspended after step 1 left the stop-the-world sweep a chunk that
was not dormant and entirely free. The sweep made it dormant again and
rebuilt the class list without it. The revival then resumed and installed its
chain. From then on blocks were handed out of a chunk flagged DORMANT, and
two things followed:

- The post-STW flush DONTNEEDs that chunk. On the TLAB path the flush waits
  for the reviver's `@alloc_lock`, so it runs just after the first blocks are
  handed out and zeroes them.
- The next sweep skips a dormant chunk without walking it.

The bitmap revival never had this problem: it pins the chunk with the cursor
flag across the same transition.

Now the chunk stays DORMANT while its headers are written. The sweep skips it
whole, and the class rebuild leaves it out. The chain goes on the list, and
the flag flips last, both under `@alloc_lock`. A live walk in flight, or one
that ran while the headers were written, refuses the revival instead. The
chain is spliced in front of the class list rather than over it, because a
sweep that ran meanwhile may have rebuilt that list.

**Gate:** `make chunk-search-race`, arm `handoff-header-dormant`. It
schedules a full sweep at the moment the flag clears, then asserts that no
block on the class list lies in a DORMANT chunk.

- Old code: `the class freelist hands out blocks of a DORMANT chunk`, every
  run, in both the headerless and the `-Dgcry_block_headers` build.
- New code: passes.
- An instrumented old build printed `PROBE: installed a freelist in a DORMANT
  chunk` on the same schedule.

The target's headers are written FREE before it is flagged dormant. That is
a dormant chunk whose pages the post-STW flush has not released yet, or one
that Darwin's `MADV_FREE` kept. With zeroed headers the sweep reads a refill
in progress and never reclaims (`uninitialised_small_block?`). So the window
is only open once the revival has rewritten every header: after the rewrite
and before the install.

## 3. A TLAB refill interrupted by a collection

The revival fix did not end the failures. A 1500-run local stress of the
fixed revival (`cookie_stress.py`, 6 at a time, seeds 70000–71499) still
failed **2 of 1500** with `cookie broken`. Before it, the rate was about
7 in 1150 across the runs of the lock-fixed binary: 1/200, 4/400 and 1/400,
plus 1 in about 150 of an interrupted run.

A probe on the old revival that printed whenever a sweep caught a revival
mid-way stayed silent in a failing run (seed 80002). So a second path
existed.

The TLAB refill takes a batch off the class list under `@alloc_lock` and
then installs it in the thread's TLAB. The stopped world takes no allocator
lock. A collection that stops the thread between those two steps sees a batch
that is on no list and in no TLAB; to the sweep those blocks are just free.
It can then:

- make their chunk dormant, and
- rebuild the class list (and the refill then overwrites the rebuilt list
  with the stale chain it had read before the stop).

After the stop the refill installs the batch. The first allocation writes
into it, and the post-STW flush, which had been waiting on `@alloc_lock`,
zeroes it.

A probe on the refill printed when the TLAB epoch moved between the start of
a refill and its install. It fired in **26 of 600** runs (seeds
90000–90599), every time with the batch's chunk still live. So the gap is
hit often, and the chunk itself is rarely the one made dormant. The rebuild is what can do the harm here. With the opt-in on, the rebuild of
a class list runs whenever any chunk of that class goes dormant. It relinks
every FREE block of the class's live chunks, including the batch, so the
batch ends up both on the global list and, once installed, in the TLAB. The
refill also stores its stale remainder over the rebuilt list.

This gap is real and now fixed (below), **but it was not what broke the
cookies**. The next section is.

**Gate:** `make chunk-search-race`, arm `handoff-tlab-refill`. It needs
`-Dgcry_block_headers`, because TLAB is refused headerless, so the target
now also builds that way. It runs a collection (`flush_all_tlabs` + sweep)
in the gap. The hook is `current_tlab_under_lock`, which the refill calls
there. The collection makes the batch's chunk dormant. The arm then asserts
that no TLAB block lies in a DORMANT chunk or on the class list.

| code | `handoff-header-dormant` | `handoff-tlab-refill` |
|---|---|---|
| `e13eb55` (before both fixes) | fails | fails |
| `3106e72` (revival fixed) | passes | fails |
| `cfbf386` (both) | passes | passes |

Fix: the refill runs against `@tlab_epoch`, which every collection bumps
inside the stop. If the epoch moved while the lock was held, the refill:

1. takes the batch back out of the TLAB;
2. drops the class list it may have overwritten;
3. asks the next sweep to rebuild that class (`@freelist_rebuild_request`);
4. starts over.

All of this happens before the lock is released, so the flush cannot run in
between. A collection after the check finds the batch in the TLAB and
flushes it like any other.

## 4. No TLAB was ever a thread's own, and no collection ever emptied one

Stressing `cfbf386` settled nothing at first, because the failure rate
depends on the host far more than on the code. The same binary failed 2 of
1500 in one run and 21 of 300 an hour later. Every comparison from here on
ran its arms **concurrently** under the same load.

- Three variants of the refill discard, run that way, failed 14, 15 and 16 of
  300. One of them discards nothing at all.
- The richer cookie report (`363584d`) showed what the broken roots were:
  `words=0x0,0x0`, a zeroed header, and `chunk_flags=0x2`, DORMANT. So a
  rooted object sat in a dormant chunk whose pages had been released.
- With `GCRY_PARALLEL_DORMANT=0`, the same stress failed 0 of 300.
- A probe on every TLAB hit printed when the block came from a DORMANT chunk.
  **Every** failing run had such a hit, and most of them came after a
  collection that ran during the same allocation.
- Probes on the other ways in (a refill installing a dormant block, a free
  into a TLAB) stayed silent.

The cause is in how the slots were written:

```crystal
@tlabs[i].owner = key                          # current_tlab_under_lock
@tlabs[i].live = true
@tlabs[i].freelists[c] = Pointer(Void).null    # flush_all_tlabs
```

`@tlabs` is a `StaticArray(Tlab, 64)` and `Tlab` is a struct. `@tlabs[i]`
returns a copy, so each of these assigned to a temporary and was lost. The
same lines in a ten-line program print the old value (`copytest.cr`).
`ptr.value.field = x` does write through, and the allocation paths used that
form, so TLAB appeared to work:

- No slot was ever marked live. Every thread missed the lookup, took
  `@alloc_lock`, and got slot 0. Every thread shared one TLAB. The slot lock
  in `tlab_alloc_small` was added against "two OS threads briefly sharing a
  slot", and it was guarding exactly this.
- `flush_all_tlabs` skips slots that are not live, so it flushed nothing.
  The TLAB's chain survived every collection. The sweep read those blocks as
  free, while the TLAB kept handing them out:
  - it relinked them onto the class list, so they could be handed out twice;
  - it made their chunk dormant, and the post-STW flush then released pages
    under the objects allocated from them. That is `root N cookie broken`.
- The alloc-batch table (`GCRY_ALLOC_BATCH`) had the same three writes.

All of this dates from TLAB's first commit (`51ae436`, 2026-07-24).

Fix: every slot write goes through a pointer. A thread past `MAX_TLABS`
shares a slot by key rather than calling `oom!`. The slot lock serializes the
sharers, and the flush now empties the slot, so sharing is slower but sound.

Two defects that the dead flush had hidden came up at once.

### 4a. A thread stopped inside a TLAB allocation

`tlab_alloc_small` reads its head block and that block's `next_free` under
the slot lock, then stores the new head. A thread stopped between those two
steps comes back to a TLAB the flush has emptied, and stores a stale chain
into it. The collector now takes every slot lock just before `stop_world`,
after `@roots_lock` and the finalizer lock. It releases them as soon as the
world is stopped. `GCRY_TLAB_QUIESCE=0` restores the old order for A/B.

### 4b. TLAB refills inside a stopped world

With the flush working, about 2% of loaded runs hung (21 of 900), and every
captured stack was `scrub_freelists` walking a freelist forever. A Floyd
check after each phase placed the cycle **right after `flush_all_tlabs`**,
always in class 9, in both the old and the nursery lists.

A per-block history (the last two events per address, recorded in side
tables) named the nodes on the cycle:

```
prev=[refill into TLAB slot 3, epoch 2, world stopped]  last=[rebuild, epoch 2, world stopped]
```

A thread refilled its TLAB **while the world was stopped**, after the flush
had emptied it. The sweep's rebuild then linked the same blocks onto the
class list, and the next flush spliced them in again. The thread is either:

- the collector, or
- a thread the stop missed. Epoch 2 is the second collection, when the
  context's worker threads are being born, and the CI log carries the
  matching `a thread was staged AFTER the wait ran — the world stopped without
  it` audit line.

Fix: nothing uses a TLAB while the world is stopped. `allocate` checks it,
and so does every iteration of `tlab_alloc_small`, for a thread that entered
before the stop. `tlab_refill_once` refuses under `@alloc_lock`. Such a thread
takes the class list instead, exactly as without TLAB.

That allocation in a stopped world still races the sweep. It is the general
birth-window hazard that the thread audits track, not something TLAB adds.

**Gate:** `make chunk-search-race`, arm `tlab-slots` (headered build). It
checks that a thread's slot is claimed and owned by it, that a second thread
gets a different slot, and that a collection's flush empties the chain the
refill installed. On `3106e72` it fails every run with `this thread's TLAB
slot was never claimed`.

### The stress, arms concurrent

`stw_mt_property_test_hdr --tlab --iterations=200 --workers=2,4`, three
harnesses at a time, 2 runs each:

| binary | dormant | dormant off | nursery + dormant |
|---|---|---|---|
| `cfbf386` + slot writes only | 0 cookie, 6 hangs / 300 | 0 cookie, 7 hangs / 300 | 0 cookie, 6 hangs / 300 |
| + no TLAB in a stopped world | **0 / 300** | **0 / 300** | **0 / 300** |

Paired against master (`cfbf386`), 250 runs each, four harnesses at once:

- master: 0 / 250 with dormant, 0 / 250 with nursery;
- fix: 0 / 250 with dormant, and 1 timeout in 250 with nursery.

That timeout is Crystal's scheduler deadlock: both workers are in
`parallel/scheduler.cr:97` `resume`, with no collector frame
(`bench/log/linux/2026-09-25-parallel-scheduler-deadlock/`).

At the load where master does fail, two harnesses at once, 3 runs each,
same seeds (200000–200299):

| binary | cookie broken | hangs |
|---|---:|---:|
| master (`cfbf386`) | **7 / 300** | 0 |
| fix (`3299e74`) | **0 / 300** | 1, Crystal's scheduler deadlock again |

(`captures/master-cookie-200187.log`: `words=0x0,0x0 ... chunk_flags=0x2`.)

The four-harness load did not reproduce the defect on master. The same master binary had
failed 68 of 1500 (five at a time) and 21 of 300 earlier, and the fix is
0 of 1650 across every run above. The proof is the gates. `tlab-slots`,
`handoff-tlab-refill` and `handoff-header-dormant` each fail every run on
the code before their fix.

## The rest of the campaign

`campaign-summary.md`: 1061 runs, 10.0 lane-hours. Every lane without the
header allocator passed every run:

- `stw_mt`, `stw_mt+diag`, `pattern_fuzz+diag` (4.6 lane-hours);
- `dormant_flush`, `churn`, `churn_hdr`, `index_grow`, `thread_storm`.

## Scope

Only the header allocator was affected.

- **Defects 1, 3 and 4 need `GCRY_TLAB=1`**, which `docs/HARDENING.md` lists
  as unsupported under Parallel. The process GC prints a warning for it.
- **Defect 2 needs dormant chunks.** On Linux, dormant chunks exist with
  `GCRY_PARALLEL_DORMANT` or an explicit `GCRY_EMPTY_CHUNK_RETAIN`. On Darwin
  they exist by default, from the 512 KiB budget. It was reachable there in
  headered builds without TLAB. [INFERENCE: the non-TLAB revival has the same
  flag order; the lanes did not measure it.]

## The same campaign on the fixed code

`run-dormant.py 2 5` again: every lane with `GCRY_PARALLEL_DORMANT=1`,
binaries built from `0c04eee` (`campaign2-summary.md`). It ran 1997 runs over
10.1 lane-hours with **0 failures**.

There were five timeouts. Each is Crystal's scheduler deadlock: two workers
in `parallel/scheduler.cr:97` `resume`, with no collector frame anywhere.
They fell on `stw_mt` ×2, `stw_mt+diag`, `stw_mt_hdr_tlab` and
`stw_mt_hdr_tlab_nursery` (seeds 20002, 20136, 20140, 20162, 20118).

The headered TLAB lanes, which hung 36 of 36 and then broke 4 of 79 cookies
in the first campaign, ran 364 times: 0 failures, 2 of those deadlocks.
