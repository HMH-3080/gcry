# Page-size units: the pagemap index, the guard offsets, and a wrong warning (2026-09-29)

## What was wrong

`Roots::PAGE_SIZE` is a compile-time 4096. Three kinds of use read it:

1. **Readability probes** (`Roots.scan_range_safe`, `clear_range_safe`, the
   holders search, the SEGV report's frame walk). A probe answers for the page
   its address lies in, so 4 KiB steps are right on any kernel whose page is
   4 KiB or larger — only more of them. Unchanged.
2. **The pagemap low-water probe** (`linux_pagemap.cr`). The pagemap file is
   indexed by virtual page number *in the kernel's unit*. With a 4 KiB stride
   on a 16 KiB kernel, index `addr // 4096` is the entry for `4 × addr`; on a
   64 KiB kernel, for `16 × addr`.
3. **Fiber and thread guard offsets** (`base + PAGE_SIZE` in the scan, scrub,
   birth-grace, holders and address-space-audit paths). Crystal protects its
   guard with `mprotect(pointer, 4096)`, which a 16 KiB kernel rounds up to the
   whole 16 KiB page.

And `GC.init` compared the constant with `sysconf` and printed

```
gcry: WARNING: this kernel's page size is 16384 and gcry is compiled for 4096. Page-aligned decisions — dormancy's madvise, the pagemap low-water probe, the fiber guard offset — are computed on the wrong unit here
```

on every start on a non-4 KiB kernel. On Apple Silicon that is every gcry
program: 87 times in one `test (darwin native)` job (run 36598280569). There it
was false. Darwin's dormancy `madvise` and low-water probe already use
`Platform.host_page_size` (`sysconf`), and the guard offset is only a scan start
that the probes step over.

## What the pagemap stride does on a non-4 KiB kernel

Measured on this x86_64 host (4 KiB pages), for a fresh 1 MiB mapping at
`0x7c5ee8400000`:

| read | bytes returned |
|---|---:|
| entry at `addr // 4096` (right) | 8 (`0xa18…`, present) |
| entry at `4 × addr // 4096`, what a 16 KiB kernel is asked | 0 |
| entry at `16 × addr // 4096`, what a 64 KiB kernel is asked | 0 |

The kernel answers an index past `task_size` with a short read.
`stack_low_water` then sets `@@pagemap_failed` and returns `low` for the rest of
the process. So on a 16 KiB Linux kernel with the usual 48-bit layout, the skip
turned itself off on the first call and never skipped again. Every parked
stack was then scanned whole, which is the 13.9× pause
`bench/stw_lag_pause.cr` measures without the skip. [INFERENCE]: the stacks
are mmap'd near the top of the address space, so `4 × addr` is past the end.

[INFERENCE, not measured, no such host available] A 64 KiB kernel with a
52-bit `task_size` and mmaps below 2^48 is worse. There `16 × addr` can land
inside the address space on an unmapped page. Its entry reads as neither
present nor swapped, the probe reports the range as never faulted, and live
stack is skipped.

## Change

- `Roots.runtime_page_size` reads `sysconf` on first use instead of only
  from `GC.init`. Library-mode heaps never ran `GC.init`, so they got 4096.
  `GC.init` primes it.
- `linux_pagemap.cr` indexes in `runtime_page_size`.
- The guard offsets use `runtime_page_size`: the scan starts past the whole
  protected page instead of 12 KiB inside it. The unprobed single-mutator
  scrub (`stack_scrub.cr`, `Pointer#clear`) could otherwise write into the
  protected part of a 16 KiB guard page, for a fiber whose `stack_top` is
  within the wipe window of the guard.
- `address_space_audit`'s in-flight pool-stack shape is `STACK_SIZE` minus
  the kernel page, which is what remains mapped readable.
- The warning is gone. Nothing it named is computed in the compiled unit any
  more.

On a 4 KiB kernel every changed value is identical (4096), so Linux x86_64
and aarch64 CI runners behave as before. Checked locally:

- `spec/stack_low_water_spec.cr` + `spec/stack_scrub_spec.cr`: 10 examples, 0 failures.
- `make stw-lag-pause`: PASS, skip and red arms.
- `make thread-birth-fiber`: ok.
- darwin and windows typecheck: ok.

The macOS job is where the change shows. The warning count in `test (darwin
native)` should go from 87 to 0, and the guard-offset change runs under every
Darwin gate.
