# gcry's own layout tables were 88% of the static roots

**Date:** 2026-09-28 · QEMU x86_64, 12 vCPU · Crystal 1.21.0 · old = `a9ef870`.

## Found

The per-collection trace of Kemal at EC1 under `wrk -c100` split a 634 µs
pause into:

| phase | time |
|---|---:|
| mark | 276 µs |
| roots | 166 µs |
| **static** | **138 µs** |
| stacks | 20 µs |

Static roots on Linux are the executable's writable `PT_LOAD` segments, which
came to 510 KiB here. `nm --size-sort` showed where most of it went:

| what | size |
|---|---:|
| `Gcry::Layout::offsets` | 256 KiB |
| `Gcry::Layout::index` | 32 KiB |
| 19 other `Gcry::Layout::*` tables | 160 KiB |
| **all Layout tables** | **448 KiB, 88% of the static roots** |

They are `uninitialized StaticArray` class variables. They hold type ids,
offsets, sizes and kinds, none of which can name a heap object, and every
collection read them word by word. The file's own header already warned
that tables in the process image are walked by the static scan.

## Change

The 21 tables are pointers into one zeroed `malloc` block, carved in
`Layout.alloc_tables`. Every entry point reaches it through `ensure_booted`
before it reads a table. `.bss` went from 470 KiB to 23 KiB. macOS and
Windows scan the executable's writable sections too, so the change applies
to them as well.

## Measured

`layout_ab.py` ran old, null (old again) and new concurrently, each under its
own `wrk -t2 -c100 -d15s`, with the start order rotated each round. The
figures are medians over the collections under load, from `GCRY_TRACE`. A
stress campaign loaded the host.

**EC1**, 9 rounds:

| | static | pause | req/s |
|---|---:|---:|---:|
| old | 147 µs | 683 µs | 64 732 |
| null | 147 µs | 681 µs | 64 090 |
| new | **13 µs** | **549 µs** | 65 083 |

- new − old, pause: **−134 µs (−19.6%), lower in 9/9**.
- null − old, pause: −0 µs, lower in 5/9.

**EC4**, 6 rounds: static went from 147 to 16 µs, lower in 6/6. The pause
itself cannot be resolved on this host at EC4. Three servers of four
schedulers each, on top of the campaign, put it at 5–6 ms, most of it
waiting for threads to acknowledge the stop, and the null arm moved
+109 µs. The saving per collection is the same 130 µs.

Gates: `crystal spec` (both layouts), `process_spec`,
`make layout-property-test-short`, `ivar-layout-roots` and
`static-bss-roots`.
