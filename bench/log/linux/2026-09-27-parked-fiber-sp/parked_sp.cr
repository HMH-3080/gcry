require "../../../../src/gcry"
require "wait_group"

# Parked fibers on a Parallel context, each holding a heap object only in its
# own frame; a collection runs while they wait. Reports which scan the parked
# fibers got and whether every object survived.
class Holder
  property v : Int64

  def initialize(@v)
  end
end

n = (ARGV[0]? || "200").to_i
ctx = Fiber::ExecutionContext::Parallel.new("p", 4)
gate = Channel(Nil).new
done = Channel(Bool).new(n)
n.times do |i|
  ctx.spawn do
    b = Holder.new(i.to_i64 * 7)
    gate.receive
    done.send(b.v == i.to_i64 * 7)
  end
end
sleep 200.milliseconds
h = Gcry.default_heap
before_p = h.fiber_scan_parked_sp
before_l = h.fiber_lag_scans
3.times do
  1000.times { Holder.new(0) }
  GC.collect
end
parked = h.fiber_scan_parked_sp - before_p
lagged = h.fiber_lag_scans - before_l
n.times { gate.send(nil) }
ok = (1..n).all? { done.receive }
puts "fibers=#{n} parked_sp_scans=#{parked} lag_scans=#{lagged} all_alive=#{ok}"
