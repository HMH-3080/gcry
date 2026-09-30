# Is a pointer held only in a floating-point register of a suspended thread a
# root?
#
# LLVM moves pointers through FP/SIMD registers (copies, memcpy, vectorised
# loops), and a thread can be stopped with the only copy there. Each platform
# reaches those registers differently:
#
#   Linux    the suspend is a signal, and the kernel saves the FP/SIMD state
#            in the signal frame below the reported SP, which the scan keeps
#            in its window (`suspended_sp_slack`,
#            `bench/log/linux/2026-08-27-signal-frame-below-sp/`)
#   Windows  `GetThreadContext` returns the XMM / NEON registers and they are
#            scanned with the general-purpose ones
#   macOS    `thread_suspend` leaves the state in the kernel; gcry reads it
#            with `thread_get_state`
#
# A spawned thread moves the block's address into `d8` (aarch64) or `xmm8`
# (x86_64) inside one asm block, clears the general-purpose copy and spins
# there, so no other copy exists while main collects. The address travels
# XOR'd everywhere else.
#
#   bin/fp_register_root            held only in an FP register: must survive
#   bin/fp_register_root --control  held nowhere: must die, or the survival
#                                   above is not attributable to the register
#
#   crystal build -Dgc_none bench/fp_register_root.cr -o bin/fp_register_root

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "fp_register_root requires -Dgc_none (gcry as process GC)" %}
{% end %}

SIZE =                        96
FILL =                   0xa5_u8
KEY  = 0x5A5A_A5A5_5A5A_A5A5_u64

CONTROL = ARGV.includes?("--control")
HEAP    = Gcry.default_heap.not_nil!

# Plain memory for the handshake, so nothing the collector scans holds more
# than flags.
FLAGS = LibC.malloc(16).as(Int32*)
FLAGS[0] = 0 # holder is in its loop
FLAGS[1] = 0 # main is done collecting

@[NoInline]
def make_victim : UInt64
  ptr = GC.malloc_atomic(SIZE).as(UInt8*)
  SIZE.times { |i| ptr[i] = FILL }
  ptr.address ^ KEY
end

@[NoInline]
def wipe_stack : Nil
  buf = uninitialized UInt8[16384]
  buf.to_unsafe.clear(16384)
  Gcry::Roots.keep_alive(buf.to_unsafe.as(Void*))
end

# Put `hidden ^ KEY` in an FP register, zero every GP copy, raise the ready
# flag and spin until main says it is done. Returns the register's value.
@[NoInline]
def hold_in_fp_register(hidden : UInt64, key : UInt64, ready : Int32*, done : Int32*) : UInt64
  out = 0_u64
  {% if flag?(:aarch64) %}
    asm("eor x9, $1, $2
         fmov d8, x9
         mov x9, #0
         mov w10, #1
         str w10, [$3]
         1:
         yield
         ldr w10, [$4]
         cbz w10, 1b
         fmov $0, d8"
            : "=r"(out)
            : "r"(hidden), "r"(key), "r"(ready), "r"(done)
            : "x9", "x10", "d8", "memory"
            : "volatile")
  {% elsif flag?(:x86_64) %}
    asm("movq $1, %rax
         xorq $2, %rax
         movq %rax, %xmm8
         xorl %eax, %eax
         movl $$1, ($3)
         1:
         pause
         movl ($4), %ecx
         testl %ecx, %ecx
         jz 1b
         movq %xmm8, $0"
            : "=r"(out)
            : "r"(hidden), "r"(key), "r"(ready), "r"(done)
            : "rax", "rcx", "xmm8", "memory"
            : "volatile")
  {% else %}
    {% raise "fp_register_root: aarch64 and x86_64 only" %}
  {% end %}
  out
end

hidden = make_victim
wipe_stack
holder_hidden = CONTROL ? 0_u64 : hidden

held = Atomic(UInt64).new(0_u64)
holder = Thread.new(name: "fp-holder") do
  # The control arm passes a value that decodes to nothing gcry allocated.
  v = hold_in_fp_register(holder_hidden, KEY, FLAGS, FLAGS + 1)
  held.set(v)
end

until Atomic::Ops.load(FLAGS, :acquire, true) == 1
  Thread.sleep(1.millisecond)
end
wipe_stack
3.times { GC.collect }

victim = Pointer(Void).new(hidden ^ KEY)
alive = HEAP.live?(victim)
intact = false
if alive
  bytes = victim.as(UInt8*)
  intact = (0...SIZE).all? { |i| bytes[i] == FILL }
end
Atomic::Ops.store(FLAGS + 1, 1, :release, true)
holder.join

round_trip = held.get == victim.address
puts "=== is a pointer held only in an FP register a root? ==="
puts "mode: #{CONTROL ? "control (held nowhere; the block must die)" : "held only in #{{{ flag?(:aarch64) ? "d8" : "xmm8" }}}"}"
puts "victim 0x#{victim.address.to_s(16)}: live?=#{alive}#{alive ? " intact=#{intact}" : ""}; register round trip #{CONTROL ? "n/a" : round_trip}"

if CONTROL
  if alive
    puts "INCONCLUSIVE — the control block survived with nothing holding it"
    exit 2
  end
  puts "ok — held nowhere, the block dies"
  exit 0
end
unless round_trip
  puts "INCONCLUSIVE — the register did not hold the address to the end"
  exit 2
end
if alive && intact
  puts "ok — a pointer held only in an FP register keeps its block alive"
  exit 0
end
puts "FAIL a block whose only reference was in a suspended thread's FP register was collected"
exit 1
