# Parallel mark on a narrow graph: two lock trips per node (2026-10-01)

## How it was found

The gate-coverage probe on native Windows arm64 ran `make parallel-mark-process`.
Its parallel arm hung 6 of 6 times. The serial arm (`--disabled`) passed in one
second each time. With `GCRY_STW_WATCHDOG_MS=3000`, each collection reported
`phase=mark` stalls past 3 s, and a single run did not finish in 900 s. In the
`cdb` stacks, symbolised against the uploaded exe's COFF symbols, the master
was in `mark_drain_finished?` and the workers were in `pop_mark_batch` and
`flush_pushbuf`, all inside `Crystal::SpinLock#lock` on `@mark_lock`.

## It is not Windows arm64

`chain_time.cr` (beside this file) builds one linked chain and times
`GC.collect` per `GCRY_PARALLEL_MARK`. Old protocol, ms per collection:

| | 1 worker | 2 | 3 | 4 |
|---|---:|---:|---:|---:|
| Linux x86_64, 200 000 nodes | 4.7 | — | — | 834 |
| Windows arm64 (4 cores), 200 000 nodes | 7.9 | 576 | 3 823 | > 30 000 (4 collects past 120 s) |
| the same, `--mattr=+lse` | 7.5 | 507 | 1 297 | 2 678 |

On a chain each scanned node has one child. The protocol published every
batch's children to the shared stack, so each node cost a flush under
`@mark_lock` and a pop under it by some other worker, with all workers
contending for one lock. LSE atomics help on arm64, but the protocol is the
cost.

## Change

`scan_batch_local_first`: after scanning a batch, a worker keeps scanning
its own push buffer while it holds at most `MARK_LOCAL_DRAIN_MAX` (4)
entries, and flushes when it holds more. The termination argument is
unchanged: the worker is counted busy from the pop until the `add(-1)` after
its final flush.

`bench/parallel_mark_process.cr` marked one chain. It now marks 256 chains
hanging off an array: with a single chain, nobody steals any more.

## Chain, after

| | 1 worker | 2 | 4 |
|---|---:|---:|---:|
| Linux x86_64, 200 000 nodes, threshold 4 | 4.7 | 9.3 | 20.9 |

## Wide graph: the threshold

`gc_phases --seconds=2 --survival=0.5 --fanout=6 --shuffle`, pause per
collection, interleaved in random order. Raw rows are in `wide-threshold*.tsv`.

| object size, workers | threshold 64 vs old | threshold 4 vs old |
|---|---|---|
| 64 B, 1 (serial path, unchanged) | +2.0% (t=1.2) | −1.8% (t=−0.8) |
| 64 B, 2 | +6.4% (t=2.7) | +0.5% (t=0.1) |
| 64 B, 4 | +7.7% (t=3.0) | +3.9% (t=2.5) |
| 512 B, 1 (serial path, unchanged) | +2.3% (t=1.9) | +4.7% (t=3.3) |
| 512 B, 2 | +1.8% (t=0.8) | +3.3% (t=1.6) |
| 512 B, 4 | +8.8% (t=3.2) | −0.4% (t=−0.1) |

At 64, a fanout-6 node grows two levels locally before anyone can share it,
and 4 workers lose 5–8%. At 4, every difference is within what the
*unchanged* serial path moved between the two builds (+4.7%, t=3.3), which is
this host's floor for a build-to-build comparison. The 2026-09-23 local drain
(`../2026-09-23-parallel-mark-scaling/`) published only to an idle peer and
was measured on this wide graph alone, where neither version wins. The chain
is where it matters.

## Second change: an idle worker does not take the lock to find nothing

After the local drain, native Windows arm64 marked the chain in 25 ms with 4
workers. But `parallel-mark-process`, now with stealing, took 33–44 s against
1 s serial, and `parallel-mark-termination` did not finish in 600 s. Every
`pop_mark_batch` took `@mark_lock` to find the stack empty, and each take is
a write to the lock's line that slows whoever has work to push.
`MarkStack#empty_unlocked?` (an atomic monotonic load of `@size`) is read
first, and a worker that sees an empty stack returns without the lock. It
takes nothing and is not counted busy, so termination is unaffected.

Native Windows arm64 (4 cores), final tree:

| | before | local drain | + unlocked peek |
|---|---|---|---|
| chain, 4 workers, ms/collection | > 30 000 | 25.4 | 8.2 (serial 7.6) |
| `parallel_mark_process` | hangs (6 of 6 killed at 120 s) | 33–44 s | 5–8 s |
| `parallel_mark_termination` | — | killed at 600 s | passes, 170 s |

Wide graph on Linux, final tree against the old protocol, n=6
(`wide-final.tsv`): 64 B +0.8% / +4.1% / +3.3% at 1 / 2 / 4 workers, 512 B
−0.3% / +1.5% / +3.3%, none significant (t ≤ 1.7).

Gates on Linux after the change: `parallel-mark-process` 3 of 3 at threshold 4
and 5 of 5 at 64, all with stealing (340 000–536 000 stolen per run), `parallel-mark-termination` (shipped arm
clean, unlocked arm red), `spec/mt_spec.cr`, `process_spec/process_gc_spec.cr`,
`thread-census-names`, and `stw_mt_property_test` with `GCRY_PARALLEL_MARK=4`
on 3 seeds.
