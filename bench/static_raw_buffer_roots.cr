# Is a raw buffer of references that only a class variable holds a root?
#
# `@@buf = Pointer(String).malloc(n)` and `@@items = Slice(String).new(n) {..}`
# are ordinary Crystal. The class variable sits in the executable's writable
# segment, which the collector scans as a static root, and the buffer it names
# is a non-atomic block whose first word is its first element's address.
#
# Until 2026-09-29 static roots went through the type_id gate, which drops a
# non-atomic block unless its first `Int32` looks like a Crystal type id
# (1..1 000 000). A heap address's low half almost never does, so the buffer
# was swept while the class variable still named it. Reading it back crashed
# in 3 of 3 runs.
#
#   shipped  no gate on static roots: every string reads back.
#   red      `GCRY_TYPE_ID_GATE=1`: the old default. Every run must lose the
#            buffer or die, or this harness is not reaching the gate.
#
#   crystal build -Dgc_none bench/static_raw_buffer_roots.cr -o bin/static_raw_buffer_roots
#   bin/static_raw_buffer_roots

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "static_raw_buffer_roots requires -Dgc_none (gcry as process GC)" %}
{% end %}

N = 64

class Holder
  @@buf = Pointer(String).null
  @@slice = Slice(String).empty

  # In a frame of its own, so the stack keeps no copy of either buffer.
  @[NoInline]
  def self.fill : Nil
    @@buf = Pointer(String).malloc(N)
    N.times { |i| @@buf[i] = "raw-#{i}-" + "x" * 40 }
    @@slice = Slice(String).new(N) { |i| "slice-#{i}-" + "y" * 40 }
  end

  def self.buf_live? : Bool
    Gcry.default_heap.not_nil!.live?(@@buf.as(Void*))
  end

  def self.slice_live? : Bool
    Gcry.default_heap.not_nil!.live?(@@slice.to_unsafe.as(Void*))
  end

  def self.bad : Int32
    bad = 0
    N.times { |i| bad += 1 unless @@buf[i] == "raw-#{i}-" + "x" * 40 }
    N.times { |i| bad += 1 unless @@slice[i] == "slice-#{i}-" + "y" * 40 }
    bad
  end
end

@[NoInline]
def wipe_stack : Nil
  buf = uninitialized UInt8[16384]
  buf.to_unsafe.clear(16384)
  Gcry::Roots.keep_alive(buf.to_unsafe.as(Void*))
end

if ARGV.includes?("--child")
  Holder.fill
  wipe_stack
  # Churn between collections, so a swept buffer's memory is handed out again
  # and a read through the class variable sees someone else's data.
  5.times do
    GC.collect
    junk = Array.new(20_000) { |i| "junk#{i}" * 3 }
    junk.clear
  end
  GC.collect
  buf_live = Holder.buf_live?
  slice_live = Holder.slice_live?
  unless buf_live && slice_live
    puts "child: buffer live?=#{buf_live} slice live?=#{slice_live}"
    exit 1
  end
  bad = Holder.bad
  puts "child: buffer live?=true slice live?=true bad=#{bad}"
  exit bad == 0 ? 0 : 1
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
RUNS = 3

puts "=== a raw buffer held only by a class variable ==="
failures = [] of String

RUNS.times do
  r = BoundedChild.run(exe, ["--child"], {} of String => String, 60.seconds)
  puts "  shipped: #{r.timed_out ? "timed out" : (r.output.lines.find(&.starts_with?("child:")) || "died")}"
  failures << "shipped: a class variable's raw buffer was lost or unreadable" unless r.ok && r.output.includes?("bad=0")
end

red = 0
RUNS.times do
  r = BoundedChild.run(exe, ["--child"], {"GCRY_TYPE_ID_GATE" => "1"}, 60.seconds)
  puts "  red (GCRY_TYPE_ID_GATE=1): #{r.timed_out ? "timed out" : (r.output.lines.find(&.starts_with?("child:")) || "died")}"
  red += 1 unless r.ok && r.output.includes?("bad=0")
end
if red < RUNS
  failures << "red arm: #{RUNS - red} of #{RUNS} gated runs kept the buffer, so this harness does not reach the static gate"
end

puts ""
if failures.empty?
  puts "ok — the buffers survive without the static gate, and the gate loses them in #{red} of #{RUNS}"
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
