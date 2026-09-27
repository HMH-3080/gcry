require "../../../../../src/gcry"
require "wait_group"

# N workers each build and drop binary trees; a long-lived tree per worker
# keeps some live data. Chunks empty every cycle and are needed again the next,
# which is the worst case for releasing empty chunks' pages.
class Node
  property l : Node?
  property r : Node?

  def initialize(@l, @r)
  end

  def check : Int32
    1 + (l.try(&.check) || 0) + (r.try(&.check) || 0)
  end
end

module Trees
  def self.make(d : Int32) : Node
    d == 0 ? Node.new(nil, nil) : Node.new(make(d - 1), make(d - 1))
  end
end

n = (ENV["EC"]? || "4").to_i
depth = (ENV["DEPTH"]? || "16").to_i
iters = (ENV["ITERS"]? || "40").to_i
Fiber::ExecutionContext.default.resize(n)

t0 = Time.monotonic
wg = WaitGroup.new(n)
sum = Atomic(Int64).new(0)
n.times do |w|
  spawn do
    keep = Trees.make(depth - 2)
    iters.times do
      sum.add(Trees.make(depth).check.to_i64)
    end
    sum.add(keep.check.to_i64)
    wg.done
  end
end
wg.wait
elapsed = (Time.monotonic - t0).total_milliseconds
GC.collect
rss = File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i
hwm = File.read("/proc/self/status")[/VmHWM:\s+(\d+)/, 1].to_i
puts "ms=#{elapsed.round(1)} rss_kib=#{rss} hwm_kib=#{hwm} sum=#{sum.get}"
