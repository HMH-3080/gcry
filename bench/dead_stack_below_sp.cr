# Does a stale pointer in the dead stack just below a suspended thread's SP keep
# its block alive?
#
# The scan of a suspended thread starts `STACK_SCAN_RED_ZONE +
# suspended_sp_slack` below its SP. On Linux the slack is 4 KiB, because the
# suspend is a signal and the kernel writes the interrupted FP/SIMD registers
# in the signal frame there
# (`bench/log/linux/2026-08-27-signal-frame-below-sp/`). Everything else in
# that window is dead: frames the thread returned from. On macOS (Mach
# `thread_suspend`) and Windows (`SuspendThread`) the registers stay in the
# kernel and are read directly (`bench/fp_register_root.cr`), so there the
# window is only dead stack, and one stale word in it pins whatever it names.
#
# A spawned thread fills a 4 KiB local buffer with the block's address, returns
# from that frame, and sleeps in a loop, so the copies lie in the dead area
# below its SP. The address travels XOR'd everywhere else. Main collects and
# asks whether the block survived.
#
#   bin/dead_stack_below_sp --expect-freed  the dead copies must not keep it
#   bin/dead_stack_below_sp --expect-kept   they must (Linux with the slack)
#   bin/dead_stack_below_sp --control       the thread also keeps the address
#                                           live above its SP: must survive
#
#   crystal build -Dgc_none bench/dead_stack_below_sp.cr -o bin/dead_stack_below_sp

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "dead_stack_below_sp requires -Dgc_none (gcry as process GC)" %}
{% end %}

SIZE  =                        96
KEY   = 0x5A5A_A5A5_5A5A_A5A5_u64
WORDS =                       512

CONTROL      = ARGV.includes?("--control")
EXPECT_FREED = ARGV.includes?("--expect-freed")
EXPECT_KEPT  = ARGV.includes?("--expect-kept")
HEAP         = Gcry.default_heap.not_nil!

@[NoInline]
def make_victim : UInt64
  GC.malloc_atomic(SIZE).address ^ KEY
end

@[NoInline]
def wipe_stack : Nil
  buf = uninitialized UInt8[16384]
  buf.to_unsafe.clear(16384)
  Gcry::Roots.keep_alive(buf.to_unsafe.as(Void*))
end

# Leave copies of the address across 4 KiB of this frame, then return: after
# that they are below the caller's SP.
@[NoInline]
def plant(hidden : UInt64) : UInt64
  buf = uninitialized UInt64[WORDS]
  addr = hidden ^ KEY
  WORDS.times { |i| buf[i] = i.even? ? addr : 0_u64 }
  Gcry::Roots.keep_alive(buf.to_unsafe.as(Void*))
  buf[WORDS - 1]
end

# The fill loop leaves the address in scratch registers, general-purpose and
# (vectorised) SIMD, and a suspended thread's registers are roots. Zero them
# so the dead stack is the only place left.
@[NoInline]
def scrub_volatile_registers : Nil
  {% if flag?(:x86_64) %}
    asm("xorl %eax, %eax
         xorl %ecx, %ecx
         xorl %edx, %edx
         xorl %esi, %esi
         xorl %edi, %edi
         xorl %r8d, %r8d
         xorl %r9d, %r9d
         xorl %r10d, %r10d
         xorl %r11d, %r11d
         pxor %xmm0, %xmm0
         pxor %xmm1, %xmm1
         pxor %xmm2, %xmm2
         pxor %xmm3, %xmm3
         pxor %xmm4, %xmm4
         pxor %xmm5, %xmm5
         pxor %xmm6, %xmm6
         pxor %xmm7, %xmm7"
 ::: "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11",
     "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7"
 : "volatile")
  {% elsif flag?(:aarch64) %}
    asm("mov x0, #0
         mov x1, #0
         mov x2, #0
         mov x3, #0
         mov x4, #0
         mov x5, #0
         mov x6, #0
         mov x7, #0
         mov x8, #0
         mov x9, #0
         mov x10, #0
         mov x11, #0
         mov x12, #0
         mov x13, #0
         mov x14, #0
         mov x15, #0
         movi v0.2d, #0
         movi v1.2d, #0
         movi v2.2d, #0
         movi v3.2d, #0
         movi v4.2d, #0
         movi v5.2d, #0
         movi v6.2d, #0
         movi v7.2d, #0
         movi v16.2d, #0
         movi v17.2d, #0
         movi v18.2d, #0
         movi v19.2d, #0"
 ::: "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10",
     "x11", "x12", "x13", "x14", "x15", "d0", "d1", "d2", "d3", "d4", "d5",
     "d6", "d7", "d16", "d17", "d18", "d19"
 : "volatile")
  {% end %}
end

hidden = make_victim
wipe_stack

planted = Atomic(Int32).new(0)
done = Atomic(Int32).new(0)
# Two bodies rather than one with a branch: `CONTROL ? addr : null` compiles to
# a select, which computes the address on both arms and left it in a live
# slot above the SP, so the plain arm kept its block on every run.
holder = if CONTROL
           Thread.new(name: "dead-stack") do
             plant(hidden)
             live = Pointer(Void).new(hidden ^ KEY)
             planted.set(1)
             until done.get == 1
               Thread.sleep(1.millisecond)
             end
             # Used after the loop, so it is live across it.
             Gcry::Roots.keep_alive(live)
           end
         else
           Thread.new(name: "dead-stack") do
             plant(hidden)
             scrub_volatile_registers
             planted.set(1)
             until done.get == 1
               Thread.sleep(1.millisecond)
             end
           end
         end

until planted.get == 1
  Thread.sleep(1.millisecond)
end
wipe_stack
3.times { GC.collect }
alive = HEAP.live?(Pointer(Void).new(hidden ^ KEY))
done.set(1)
holder.join

puts "=== a stale pointer below a suspended thread's SP ==="
puts "mode: #{CONTROL ? "control (also live above the SP)" : "only in dead stack below the SP"}; " \
     "slack #{HEAP.suspended_sp_slack} B"
puts "victim live?=#{alive}"

if CONTROL
  if alive
    puts "ok — held live above the SP, the block survives"
    exit 0
  end
  puts "FAIL the control lost a block the thread held live"
  exit 1
end
if EXPECT_FREED
  if alive
    puts "FAIL a word in dead stack below a suspended thread's SP kept the block alive"
    exit 1
  end
  puts "ok — dead stack below the SP holds nothing"
  exit 0
end
if EXPECT_KEPT
  if alive
    puts "ok — the slack below the SP is scanned"
    exit 0
  end
  puts "FAIL the slack window was expected to keep the block"
  exit 1
end
puts alive ? "kept" : "freed"
