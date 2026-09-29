# Does a thread leaving the fiber list during a stop cut the collector's walk short?
#
# `Thread#start` ends by taking itself off Crystal's thread list and then its
# main fiber off the fiber list (`Fiber.inactive`). The stop suspends only the
# threads on the thread list. A thread that took itself off before the stop
# took `Thread.lock` is not suspended, and it goes on to `Fiber.inactive`
# while the collector walks the fiber list with `Fiber.unsafe_each` and no
# lock. `Thread::LinkedList#delete` sets the removed node's `next` to nil. A
# walk standing on that node reads nil and stops, and every fiber after it
# has its stack go unscanned for the whole collection: what only those stacks
# held is swept.
#
# Here, short-lived threads are created alongside parked "holder" fibers.
# Each holder keeps an object on its own stack and nowhere else. Collections
# run back to back, and afterwards every holder checks its object's stamp. To
# make the window land, two things are widened:
#   - `Thread#start` below is Crystal 1.21's, verbatim, except for a random
#     wait between the two removals. That is where a busy host preempts a
#     dying thread.
#   - `GCRY_FIBER_WALK_TEST_DELAY_US` spins at every fiber of the walk.
#
#   shipped  the collector holds the fiber list's mutex for the whole stop,
#            so `Fiber.inactive` waits for the resume. Every run clean.
#   red      `GCRY_FIBER_LIST_UNLOCKED=1`: the walk runs without it, as
#            before 2026-09-29. At least one run in RED_RUNS must lose a
#            holder's object or die.
#
#   crystal build -Dgc_none bench/fiber_list_exit_race.cr -o bin/fiber_list_exit_race
#   bin/fiber_list_exit_race

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "fiber_list_exit_race requires -Dgc_none (gcry as process GC)" %}
{% end %}

module ExitGap
  @@max_us = 0

  def self.max_us=(v : Int32)
    @@max_us = v
  end

  # Raw: a dying thread's main fiber is still current, and Crystal's `sleep`
  # would reschedule it.
  def self.wait : Nil
    return if @@max_us <= 0
    us = Random.rand(@@max_us)
    ts = uninitialized Gcry::OS::Timespec
    ts.tv_sec = typeof(ts.tv_sec).new(us // 1_000_000)
    ts.tv_nsec = typeof(ts.tv_nsec).new((us % 1_000_000) * 1000)
    rem = uninitialized Gcry::OS::Timespec
    Gcry::OS.nanosleep(pointerof(ts), pointerof(rem))
  end
end

class Thread
  protected def start
    Thread.threads.push(self)
    Thread.current = self
    @current_fiber = @main_fiber = fiber = Fiber.new(stack_address, self)

    if name = @name
      self.system_name = name
    end

    begin
      @func.call(self)
    rescue ex
      @exception = ex
    ensure
      Thread.threads.delete(self)
      ExitGap.wait
      Fiber.inactive(fiber)
      detach { system_close }
    end
  end
end

class Held
  getter stamp : UInt64

  def initialize(@stamp : UInt64)
  end
end

STAMP    = 0x5A17_C0DE_0000_0000_u64
HOLDERS  =                        64
ROUNDS   =                        40
COLLECTS =                         6
RUNS     =                         3
RED_RUNS =                         5
WALK_US  = "150"
EXIT_US  = "20000"

if ARGV.includes?("--child")
  ExitGap.max_us = (ENV["EXIT_GAP_US"]? || EXIT_US).to_i
  make_threads = ENV["NO_THREADS"]? != "1"
  lost = Atomic(Int32).new(0)
  release = Channel(Nil).new
  done = Channel(Nil).new
  holders = 0
  ROUNDS.times do |r|
    threads = [] of Thread
    HOLDERS.times do |i|
      threads << Thread.new { } if make_threads
      id = (r * HOLDERS + i).to_u64
      spawn do
        held = Held.new(STAMP | id)
        release.receive
        lost.add(1) unless held.stamp == (STAMP | id)
        done.send nil
      end
      holders += 1
    end
    Fiber.yield
    COLLECTS.times { GC.collect }
    HOLDERS.times { release.send nil }
    HOLDERS.times { done.receive }
    threads.each(&.join)
  end
  puts "child: holders=#{holders} lost=#{lost.get}"
  exit lost.get == 0 ? 0 : 1
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
base = {"GCRY_FIBER_WALK_TEST_DELAY_US" => WALK_US, "GCRY_POISON_FREED" => "1", "GCRY_SEGV_REPORT" => "1"}

puts "=== fiber list vs a thread leaving it during a stop ==="
puts "#{RUNS} runs shipped, #{RED_RUNS} red; #{ROUNDS} rounds of #{HOLDERS} threads and holders, walk held #{WALK_US} µs a fiber"
puts ""

failures = [] of String
clean = 0
RUNS.times do
  r = BoundedChild.run(exe, ["--child"], base, 300.seconds)
  puts "  shipped: #{r.timed_out ? "timed out" : (r.output.lines.last? || "died with no output")}"
  clean += 1 if r.ok && r.output.includes?("lost=0")
end
failures << "shipped: #{RUNS - clean} of #{RUNS} runs lost a holder's object or died" if clean < RUNS

red = 0
RED_RUNS.times do
  r = BoundedChild.run(exe, ["--child"], base.merge({"GCRY_FIBER_LIST_UNLOCKED" => "1"}), 300.seconds)
  puts "  red: #{r.timed_out ? "timed out" : (r.output.lines.last? || "died with no output")}"
  red += 1 unless r.ok && r.output.includes?("lost=0")
end
if red == 0
  failures << "red arm: all #{RED_RUNS} unlocked runs came out clean, so the harness is not reaching the window and the shipped arm's silence proves nothing"
end

puts ""
if failures.empty?
  puts "ok — no holder lost with the fiber list held; unlocked, #{red} of #{RED_RUNS} runs lost one"
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
