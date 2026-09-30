# macOS: a pointer held only in an FP register was not a root (2026-09-30)

## How it came up

`make parallel-dormant` kept retaining its burst now and then. The holders
search named the holders: words 4 KiB apart in the dead area just below a
suspended thread's SP. Those words sat in the `suspended_sp_slack` window
that every platform scans below the SP. That window exists because on Linux
the suspend is a signal, and the kernel writes the signal frame there with
the interrupted FP/SIMD registers in it
(`bench/log/linux/2026-08-27-signal-frame-below-sp/`). macOS suspends with
Mach `thread_suspend`, which writes nothing on the stack, and gcry read only
the general-purpose state with `thread_get_state`. So on macOS the slack
scanned dead memory, and the FP registers were not read anywhere.

## Harness: `bench/fp_register_root.cr`, `make fp-register-root`

A spawned thread takes the block's address (passed XOR'd) and moves it into
`d8` (aarch64) or `xmm8` (x86_64) inside a single asm block. It clears the
general-purpose copy and spins in the same block, so nothing else holds the
address. Main collects three times, checks the block, then releases the
thread, which hands the register back so the harness can confirm it held the
address throughout. `--control` passes a value that decodes to no
allocation, so the block is held nowhere and must die.

## Before (probe run 36739708581, `bench/fp_register_root.cr` on master)

| runner | shipped (5) | control (3) | red arm (3) |
|---|---|---|---|
| macos-latest (arm64) | **lost 5** | died 3 | `GCRY_DISABLE_GREG_ROOTS=1`: lost 3 |
| ubuntu-24.04-arm | kept 5 | died 3 | `GCRY_SUSPENDED_SP_SLACK=0`: lost 3 |
| windows-latest | kept 5 | died 3 | `GCRY_DISABLE_GREG_ROOTS=1`: lost 3 |
| windows-11-arm | kept 5 | died 3 | `GCRY_DISABLE_GREG_ROOTS=1`: lost 3 |
| Linux x86_64 (local) | kept 5 | died 3 | `GCRY_SUSPENDED_SP_SLACK=0`: lost 5 |

So the Linux mechanism is the slack, and Windows' is the SIMD part of
`GetThreadContext`, which gcry already scanned. macOS had none.

## Fix

`darwin_stw.cr` now makes a second `thread_get_state` per suspended thread:
`ARM_NEON_STATE64` (flavor 17, `v0`–`v31`) on arm64, or `x86_FLOAT_STATE64`
(flavor 5, `xmm0`–`xmm15` from byte 168) on x86_64. The words are appended to
the thread's register row, and the row width becomes 95 and 48 words. If the
kernel refuses that state, the FP half of the row is zeroed and the refusal
is counted in `Platform.stw_fp_state_failures`.

## After (probe run 36739931036, macos-latest)

| check | result |
|---|---|
| shipped | kept 10 of 10 |
| control | died 3 of 3 |
| `GCRY_DISABLE_GREG_ROOTS=1` | lost 3 of 3 |
| `make darwin-stw-resume`, `tls-roots`, `thread-birth-fiber`, `stw-capture-coverage`, `fiber-list-exit-race` | all ok |

x86_64 macOS is type-checked (`make darwin-typecheck`), not run: there is no
Intel runner in this matrix.

## Not changed

The slack itself stays 4 KiB on macOS. It is dead memory there now that the
registers are read directly. Shrinking it would retain less, and
`parallel-dormant`'s retained burst is one example. But a precision gain
worth one retention in about 500 runs is not measurable at that rate, so it
is left for a measurement.
