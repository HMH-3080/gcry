require "../../../../src/gcry"
heap = Gcry.default_heap
heap.tlab_enabled = true
abort "tlab off" unless heap.tlab_enabled?
rounds = (ARGV[0]? || "40").to_i
stale = StaticArray(Pointer(Void), 256).new(Pointer(Void).null)
keep = [] of Array(String)
rounds.times do |r|
  objs = Array(Pointer(Void)).new(20000)
  20000.times { |i| objs << GC.malloc(16 + (i % 12) * 16) }
  # Free a spread of them explicitly: they go onto TLAB freelists as FREE
  # nodes, and a copy stays on this frame as a stale word.
  256.times do |k|
    p = objs[(k * 77 + r) % objs.size]
    GC.free(p)
    stale[k] = p
  end
  objs.clear
  keep << Array.new(200) { |i| "k#{r}-#{i}" }
  keep.shift if keep.size > 10
  GC.collect
end
GC.collect
s = GC.stats
LibC.write(2, pointerof(stale).as(UInt8*), 0)
bad = 0
keep.each_with_index do |arr, j|
  r = rounds - keep.size + j
  arr.each_with_index { |str, i| bad += 1 unless str == "k#{r}-#{i}" }
end
puts "bad=#{bad} collections=#{heap.collections} last_marked=#{heap.responds_to?(:last_marked) ? 0 : -1}"
puts "live_objects=#{heap.live_objects} heap_size=#{s.heap_size} free=#{s.free_bytes}"
