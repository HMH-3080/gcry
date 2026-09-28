require "../../../../src/gcry"
heap = Gcry.default_heap
n = (ARGV[0]? || "8").to_i
busy = ARGV.includes?("--busy")
fds = uninitialized Int32[2]
LibC.pipe(fds)
stop = Atomic(Int32).new(0)
n.times do
  Thread.new do
    if busy
      x = 0_u64
      until stop.get == 1
        x &+= 1
      end
    else
      b = uninitialized UInt8[1]
      LibC.read(fds[0], b.to_unsafe, 1)
    end
  end
end
sleep 200.milliseconds
starts = [] of UInt64
stops = [] of UInt64
300.times do
  GC.collect
  starts << heap.last_phase_stw_start_ns
  stops << heap.last_phase_stw_stop_ns
end
stop.set(1)
starts.sort!
stops.sort!
puts "threads=#{n} busy=#{busy} stw_start p50=#{starts[150] // 1000}us p90=#{starts[270] // 1000}us  stw_stop p50=#{stops[150] // 1000}us"
