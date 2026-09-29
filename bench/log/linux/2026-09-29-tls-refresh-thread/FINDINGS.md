# The static-root refresh swapped the main thread's TLS for the collector's (2026-09-29)

## Sighting

The new `make thread-birth-fiber` gate failed on Windows arm64 (default
variant, master `8bc3b35`), 3 000 births:

```
gcry: static roots collapsed to 16096 bytes from 44944 — globals are not roots this collection. collection 320
Invalid memory access (C0000005) at address 0x1a1311e0b10
```

## Cause

On Windows (`windows_roots.cr`) and macOS (`darwin_roots.cr`), the static
root set is the executable's writable image plus **the main thread's
thread-local block**. That block was located through
`pointerof(@@tls_anchor)`, a gcry `@[ThreadLocal]`, whose address is the
*calling* thread's block. The comment said this runs in `GC.init`. It also
ran on every refresh. The cache is invalidated every 64 majors
(`STATIC_ROOT_REFRESH_INTERVAL`) and rebuilt by whichever thread collects
next. When that was a spawned thread, its own block replaced the main
thread's, and the main thread's thread-locals left the root set until the
next refresh happened to land on main.

Linux resolves its ranges once and never had this.

## Fix

The main thread's range is computed once, in `GC.init` on the main thread,
and pushed from the memo on every refresh. `tls_root_range` answers `{0, 0}`
while `GCRY_TLS_ROOTS=0`.

## Gate: `bench/tls_roots.cr --collect-elsewhere`

The block is held only in a main-thread `@[ThreadLocal]`. A spawned thread
runs 70 collections, past the refresh at major 64, and then main checks the
block. It is in `make tls-roots` (Linux and macOS CI) and in the Windows
default variant.

Paired on probe run 36622702389. Each job builds pre (`e69e36f`) and post
from the same tree and runs them interleaved:

| runner | pre | post |
|---|---|---|
| macos-latest | 5 of 5 lost the block | 5 of 5 kept it |
| windows-latest (x86_64 MSVC) | 5 of 5 lost the block | 5 of 5 kept it |

Linux x86_64 (local): kept, and `GCRY_TLS_ROOTS=0` still loses it.

The same job ran `thread_birth_fiber 3000`, 3 times each way on Windows. One
pre run printed `static roots collapsed to 20328 bytes from 46840` at
collection 192. No post run did.
