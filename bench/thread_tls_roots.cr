# Is a block held only in a *spawned* thread's `@[ThreadLocal]` a root?
#
# `make tls-roots` asks this of the main thread, whose thread-locals the loader
# places with the executable's. A spawned thread's live block is somewhere
# else on every platform: glibc puts it at the top of the thread's stack
# mapping, Darwin's TLV allocates it with `malloc`, and Windows copies the
# template into a block the TEB points at. The pthread-stack scan covers the
# first; nothing in gcry's root set names the other two.
#
# Crystal's own contract is that a `@[ThreadLocal]` is **not** reachable by
# the GC: `Object.thread_local` (object.cr) stores every value on the
# `Thread` object as well, for exactly that reason, and the stdlib's
# thread-locals are `Thread` objects rooted by the thread list or go through
# that macro. So this asks what gcry gives beyond the contract, and the answer
# depends on the platform (2026-09-29, all runners):
#
#   Linux x86_64, aarch64   yes: the block is inside the stack mapping gcry
#                           already scans. This gate keeps it that way.
#   macOS, Windows          no, 5 of 5 lost. Boehm gives no more, and the
#                           contract does not ask for it.
#
# A spawned thread allocates a block, stores its only reference in a
# thread-local, wipes the frames it used and waits. Main collects three times
# and asks whether the block is still allocated. The address travels XOR'd,
# so a stray copy cannot be what keeps it alive.
#
#   bin/thread_tls_roots            held only in the thread-local: must survive
#   bin/thread_tls_roots --control  held nowhere: must die, or the survival
#                                   above is not attributable to the thread-local
#
#   crystal build -Dgc_none bench/thread_tls_roots.cr -o bin/thread_tls_roots

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "thread_tls_roots requires -Dgc_none (gcry as process GC)" %}
{% end %}

SIZE =                        96
FILL =                   0xa5_u8
KEY  = 0x5A5A_A5A5_5A5A_A5A5_u64

class ThreadTls
  @[ThreadLocal]
  @@slot = Pointer(UInt8).null

  def self.slot=(value : Pointer(UInt8))
    @@slot = value
  end
end

CONTROL = ARGV.includes?("--control")

# Atomic, so no type-id heuristic can be what decides it.
@[NoInline]
def make_victim : UInt64
  ptr = GC.malloc_atomic(SIZE).as(UInt8*)
  SIZE.times { |i| ptr[i] = FILL }
  ThreadTls.slot = ptr unless CONTROL
  ptr.address ^ KEY
end

@[NoInline]
def wipe_stack : Nil
  buf = uninitialized UInt8[16384]
  buf.to_unsafe.clear(16384)
  Gcry::Roots.keep_alive(buf.to_unsafe.as(Void*))
end

hidden = Atomic(UInt64).new(0_u64)
ready = Atomic(Int32).new(0)
done = Atomic(Int32).new(0)

thread = Thread.new do
  hidden.set(make_victim)
  wipe_stack
  ready.set(1)
  until done.get == 1
    Thread.sleep(1.millisecond)
  end
end

until ready.get == 1
  Thread.sleep(1.millisecond)
end
3.times { GC.collect }
heap = Gcry.default_heap.not_nil!
alive = heap.live?(Pointer(Void).new(hidden.get ^ KEY))
done.set(1)
thread.join

puts "=== is a spawned thread's thread-local storage a root? ==="
puts "mode: #{CONTROL ? "control (held nowhere; the block must die)" : "held only in a spawned thread's @[ThreadLocal]"}"
puts "victim live?=#{alive}"
if CONTROL
  if alive
    puts "FAIL the control's block survived, so something other than the thread-local keeps it and the other arm proves nothing"
    exit 1
  end
  puts "ok — held nowhere, the block dies"
else
  unless alive
    puts "FAIL a block whose only reference is a spawned thread's @[ThreadLocal] was collected: that thread's TLS is not a root"
    exit 1
  end
  puts "ok — a pointer held only in a spawned thread's thread-local keeps its block alive"
end
