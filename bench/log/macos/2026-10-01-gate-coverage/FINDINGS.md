# Which Linux gates hold on macOS (2026-10-01)

The Linux CI jobs run about 70 `make` gates that the macOS job did not. A probe
(run 36808891888) ran 38 of them once each on macos-latest, at most 600 s per
gate. The rest are Linux-only by construction: `/proc`, signal-based stops,
soft-dirty, `RLIMIT_AS` and similar.

## Passed, controls included — now in CI as `test (darwin native, gates)`

poison-freed, poison-holders, finalizer-complex, holders-find,
parallel-mark-process, parallel-mark-termination, monitor-gate-deadlock,
thread-birth-root, thread-staging, nursery-tlab-smoke, trace-smoke,
ignored-knob-warnings, bitmap-marks-freelist, mark-audit,
released-range-report, segv-region-report, index-grow-race, large-cache-race,
nested-spawn-uaf, explicit-collect-barrier, stw-slot-precision, heap-counters,
counter-loss, interior-only-buffer, unaligned-only-buffer, stw-mt-sample.

`thread-uaf-sample` passed but took 354 s and is left out.

## Failed on the shipped arm: a Darwin bug

`stw-index-race`: 90 unlocked chunk-index reads by mutators during a stop.
Fixed. See `../2026-10-01-darwin-index-late-clear/`.

## Failed on the harness, fixed, now in CI

- `kept-release-report`: the report printed both lines. The harness looked
  for `SIGSEGV at`, and macOS reports a read of a PROT_NONE page as SIGBUS.
- `idle-release`: 1 of 3 runs ran 7 599 finalizers where the bound was 7 600.
  The bound now allows one more burst; the defect it guards was ~4 800 short.

## Controls that do not reproduce on macOS (the gate says nothing there)

- `find-block-race`: the `live` control crashed 0 of 40; `realloc` crashed.
- `thread-churn-uaf`: the poisoned control faulted 0 of 32.
- `stw-slots-grow-race`: freeing the predecessor was survived 3 of 3; macOS
  malloc does not unmap a freed small block.
- `thread-block-audit`: the `staged` arm needs Linux's raw-pthread staging.

## Not applicable or not measured

- `thread-tls-roots`: a spawned thread's `@[ThreadLocal]` is not a root on
  macOS. That is documented (Crystal's contract does not ask for it; Boehm
  does not give it either) and the harness header says so.
- `oom-no-hang`: killed at 600 s. macOS does not enforce `RLIMIT_AS`, so the
  child never runs out of address space.
- `mark-clear-index`, `chunk-list-drift`: killed at 600 s while still
  running arms. Not diagnosed.

## Windows

The same probe pattern on Windows (2026-10-01) gave three things. `large-cache-race`
discriminates there (unlocked control 5 of 5 `C0000005`) and is now in Windows
CI. The STW watchdog gate passes without the signal-wait arms. `stw-index-race`
did not discriminate until the red arm was honoured there too. All three are in
Windows CI. `index-lock-wedge` does not reproduce its wedge on Windows.

Native Windows arm64 stress (probe run 36804662991, three windows-11-arm
shards, 95 minutes each, the Crystal ARM64 GNU build): 2 813 runs and 0 failures
or stalls. The earlier windows-11-arm numbers were x64 binaries under
emulation.
