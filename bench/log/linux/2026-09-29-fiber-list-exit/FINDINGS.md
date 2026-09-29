# A dying thread cut the collector's fiber walk short

**Date:** 2026-09-29 · QEMU x86_64, 12 vCPU · Crystal 1.21.0 · old = `87e5eb2`.

## How it was found

The open ROADMAP item "a thread gcry has not heard of yet is neither stopped
nor scanned" needed to know what an unlisted thread does during a stop. So
the thread census gained a second look at the end of the stop, just before
the resume (`Heap#census_end_of_stop`, under `GCRY_THREAD_CENSUS=1`).

`thread_storm --workers=16` with `GCRY_STAGED_WAIT=0` and a 20 ms stop gave
one gap in twelve runs. The task that was outside the list at the start of
the stop was gone by its end, so it was a thread **exiting**, not being born.

For the birth side, Crystal 1.21 answers the question. `Thread#start` pushes
itself onto the thread list first, and the push takes the list's mutex,
which the collector holds for the whole stop. So a thread outside the list
is either before the push, where nothing touches the heap, or blocked in it.

The exit side is open. `Thread#start`'s `ensure` runs:

```crystal
Thread.threads.delete(self)   # off the thread list: no longer suspended
Fiber.inactive(fiber)         # off the fiber list, with no lock the collector holds
detach { system_close }
```

The collector walks the fiber list with `Fiber.unsafe_each` and no lock
while the world is stopped. `Thread::LinkedList#delete` does
`node.next = nil`. If the walk is standing on the dying thread's main fiber
when the delete lands, it reads nil and stops. Every fiber after that node
is then left out of the collection's root scan: its stack is not read, and
what only that stack holds is swept.

## Shown

`bench/fiber_list_exit_race.cr` runs 40 rounds. Each round creates 64
short-lived threads interleaved with 64 parked "holder" fibers, each holding
one stamped object on its own stack. Then come 6 `GC.collect`s, and then
every holder checks its stamp. `GCRY_POISON_FREED=1` makes a swept object
read as poison. Two things widen the window:
- the harness's copy of Crystal 1.21's `Thread#start` waits a random 0–20 ms
  between the two removals, which is where a busy host preempts a dying
  thread;
- `GCRY_FIBER_WALK_TEST_DELAY_US=150` holds the walk at every fiber.

On `87e5eb2`, one child run each:

| arm | holders lost of 2 560 |
|---|---:|
| both widened | **572, 473, 604** |
| no walk delay | 0 |
| no gap between the two removals | 0 |
| no threads created | 0 |

The three controls rule out the harness losing holders by itself, and they
rule out the walk delay doing it. The loss needs a thread between the two
removals *and* a walk that meets its node.

## Fixed

The collector takes the fiber list's own mutex before `Thread.lock` and
releases it after `Thread.unlock`, on every platform. The same applies on
the failure paths of the stop (`lock_fiber_list_for_stop` /
`unlock_fiber_list_after_stop`). A dying thread's `Fiber.inactive` then waits
for the resume.

Why it cannot deadlock:
- The mutex is taken before any thread is suspended, so no suspended thread
  holds it.
- Its critical sections (`push`, `delete`) take no other lock, so a holder
  always lets go.
- Nothing in Crystal holds the thread list's mutex while it takes this one.
- The collector touches the list only through `unsafe_each` during the stop.
- The mutex is `ERRORCHECK`, so a relock would raise rather than hang.

`GCRY_FIBER_LIST_UNLOCKED=1` restores the old walk.

`make fiber-list-exit-race`, ~30 s:

| arm | runs | holders lost |
|---|---:|---|
| shipped | 3 | 0, 0, 0 |
| `GCRY_FIBER_LIST_UNLOCKED=1` | 5 | 450, 446, 597, 681, 425 |

## The birth side of the same question

The open item had started from threads being *born* during a stop. Crystal
1.21's `Thread#start` puts `Thread.threads.push(self)` first, and the push
takes the thread list's mutex, which Linux and Windows hold for the whole
stop. So a newborn is either before the push, where it has touched no heap,
or blocked in it. macOS does not take that mutex, but a newborn's first
allocation (its main `Fiber`) waits in `allocate` for the resume.

Observed, on `thread_storm --workers=16` with `GCRY_STAGED_WAIT=0`:
- **45 gdb snapshots taken inside stops** (`GCRY_STW_TEST_STALL_MS=300`,
  the child consenting through `PR_SET_PTRACER`). Every thread was either
  suspended in `sigsuspend`, the collector, SYSMON waiting at the monitor
  gate, or gcry's idle thread. No thread was running user code.
- **The census, at the end of 30 stops with a gap.** Tasks it could not
  account for were in one of three states:
  - in `futex` (2 cases);
  - gone, having exited (14);
  - `R` with lifetime CPU time (34).

  `R` is also what a suspended mutator reads when it was preempted between
  its acknowledgement and `sigsuspend`, and the host was running a 5-lane
  campaign. So the census alone cannot say more. The snapshots can, and
  they found nothing.

## What it may explain

Nothing is attributed yet. [INFERENCE] The shape matches losses that were
never explained on thread-churn workloads: objects reachable only from the
stacks of fibers created after a thread that was exiting. How often a real
host preempts a thread between the two removals, while a walk passes its
node, has not been measured. The window is short, but it was open on every
collection that overlapped a thread exit.

## And a stop that could wait forever for a wiped acknowledgement

The first CI run with the fiber list held failed `make stw-epoch` on aarch64:
the `double+epoch` arm hung. That arm sends every thread a redundant
`SIG_SUSPEND` after each resume. The epoch should decline it, and it had
passed on all 32 runs before. Locally, with a stress campaign on the host,
the arm's child hung in **5 of 120** runs.

gdb inside the hang showed that the thread the collector was waiting for
**had** suspended. It sat in `sigsuspend` with a `SIGPWR` pending.

1. A suspend signal from the previous stop was delivered late. It had met
   the thread inside its handler and waited in the mask, and the scheduler
   then kept the thread off a CPU.
2. By the time it arrived, the next stop had already published its epoch.
   The handler admitted it as this stop's: it acknowledged, recorded the
   epoch as served, and suspended.
3. The collector then reached that thread in its send loop. That loop
   reserved each slot, which **clears its acknowledgement**, and then sent
   the signal, one thread at a time and after the epoch was out.
4. The collector's own signal waited in the handler's mask, to be declined
   later as redundant. The collector waited for an acknowledgement that
   nothing would give again.

The fix reserves every slot and clears every flag in a loop **before**
`begin_stop_epoch`, then signals. A delivery that lands before the epoch is
declined as stale. One that lands after it gives an acknowledgement the
collector no longer wipes. The first send uses a raw `pthread_kill`, not
`Thread#suspend`, because `Thread#suspend` clears the flag again just before
it signals.

| child runs, `double+epoch`, loaded host | hung |
|---|---:|
| old order, fiber list held (`e86aad2`) | 7 / 120 and 5 / 120 |
| old order, `GCRY_FIBER_LIST_UNLOCKED=1` | 0 / 120 |
| new order, fiber list held | **0 / 240** |

The race was in the epoch design, not in the fiber list lock. A real resend
can be delivered late the same way. Holding the fiber list made it far more
likely: threads that are starting up block on that mutex during a stop, get
suspended inside the wait, and receive the redundant signal while still in
their handler. `make stw-epoch` passes every arm after the change, with both
controls still red.

## Stress campaign on `e957fa4`

Both fixes were in, and the default-configuration campaign ran five lanes for
4 h (`campaign-035-summary.md`): **3 684 runs, 20 lane-hours, 0 failures,
0 timeouts.**
