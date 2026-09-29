# The static-root type_id gate swept class variables' raw buffers

**Date:** 2026-09-29 · QEMU x86_64, 12 vCPU · Crystal 1.21.0 · tree `da1f4d5`.

## Found

The `tls-roots` flake (`../2026-09-29-tls-roots-gate/`) showed that the
static-root type-id gate drops real references. Static roots are the
executable's writable segments plus the main thread's TLS block. The gate
drops any non-atomic block they point at unless its first `Int32` is between
1 and 1 000 000. The question was whether ordinary Crystal hits it. It does:

```crystal
class Holder
  @@buf = Pointer(String).null
  @@slice = Slice(String).empty
  def self.fill(n)
    @@buf = Pointer(String).malloc(n)            # non-atomic: holds references
    n.times { |i| @@buf[i] = "raw-#{i}-" + "x" * 40 }
    @@slice = Slice(String).new(n) { |i| "slice-#{i}" }
  end
end
```

Such a buffer's first word is its first element's address, and the low half
of an address almost never looks like a type id. The buffer was swept while
the class variable still named it. Reading it back crashed in **3 of 3
runs**, in `String#==` at address `0x4` or in `Pointer(String)#[]`. With
`GCRY_DISABLE_TYPE_ID_GATE=1` it read back intact.

## What the gate bought

It went in on 2026-07-24, and its own measurement then was "safe but nearly
a no-op" (acikturkiye: ~16 rejects per major, RSS unchanged). Measured
again, with `env_ab.py`: one Kemal binary in three arms (default, default
again as the null arm, gate off), run concurrently under their own
`wrk -t2 -c100 -d15s`, with the start order rotated, 9 rounds each.

| | pause | post-`GC.collect` RSS | req/s | static rejects, whole run |
|---|---:|---:|---:|---:|
| EC1 default | 472 µs | 16.4 MB | 47 709 | 1 |
| EC1 null | 476 µs | 16.5 MB | 47 872 | 1 |
| EC1 gate off | 476 µs | 16.3 MB | 47 639 | 0 |
| EC4 default | 774 µs | 20.3 MB | 93 277 | 1 |
| EC4 null | 762 µs | 20.5 MB | 101 755 | 1 |
| EC4 gate off | 765 µs | 20.3 MB | 92 566 | 0 |

Every gate-off difference is inside the null arm's. Across a whole run of
Kemal the gate rejected exactly one static root.

## Change

The gate is off by default. `GCRY_TYPE_ID_GATE=1` turns it back on for static
roots, which was the old default; it used to also gate stacks. That knob is
now research only. `GCRY_DISABLE_TYPE_ID_GATE` is gone, since it would do
nothing.

`make static-raw-buffer-roots` holds a `Pointer(String)` and a
`Slice(String)` only in class variables, churns, collects, and reads every
string back. Shipped: 3 of 3 intact. `GCRY_TYPE_ID_GATE=1`: 3 of 3 lost,
two runs crashing in `String#==` and one reporting both buffers freed. It
runs on Linux and macOS CI.

## And the blacklist, which only the gate fed

The page blacklist keeps allocation away from pages a false root pointed
into. Its only input was `note_false_root`, which only the gate called, so
with the gate off it received nothing. It still checked every free block of
a word on the bitmap refill path.

Two A/Bs, same protocol, 9 rounds each:

- **On but empty against off** (`env_ab.py`, `GCRY_DISABLE_BLACKLIST=1`):
  EC1 pause −2 µs (5/9), RSS +36 KB, req/s +1 023 (7/9). EC4 pause
  −105 µs (6/9), RSS −52 KB. The null arm moved as much: −648 req/s and
  −200 KB at EC1, −70 µs at EC4.
- **Fed the sound way against empty** (`bin_ab.py`, a throwaway build).
  Boehm's rule: a root candidate that names a *free* block marks nothing,
  and its page is blacklisted. The blacklist then skipped 12 blocks in an
  EC1 run and **538 520** in an EC4 run. EC1 pause −4 µs, RSS −136 KB,
  req/s −188; EC4 pause −108 µs, RSS −172 KB, req/s +845. The null arm
  moved −116 KB and −136 KB of RSS, and 39 µs of pause at EC4.

So the blacklist buys nothing measurable on Kemal whether or not it is fed.
It is now off by default, with `GCRY_BLACKLIST=1` to turn it on;
`GCRY_DISABLE_BLACKLIST` is gone. The sound feed was not shipped. A fat app
with a large, densely referenced heap is where it could matter, and none was
at hand to measure.
