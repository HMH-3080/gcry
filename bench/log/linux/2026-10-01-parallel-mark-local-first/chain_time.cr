require "../../../../src/gcry"

class Node
  property succ : Node? = nil
end

h = Gcry.default_heap
n = (ENV["NODES"]? || "20000").to_i
workers = (ENV["W"]? || "4").to_i
head = Node.new
cur = head
(n - 1).times { x = Node.new; cur.succ = x; cur = x }
h.parallel_mark_workers = workers
GC.collect
t0 = Time.instant
3.times { GC.collect }
dt = (Time.instant - t0).total_milliseconds / 3
walked = 0
x = head.as(Node?)
while y = x
  walked += 1
  x = y.succ
end
puts "walked=#{walked} W=#{workers} nodes=#{n} ms/collect=#{dt.round(1)} runs=#{h.parallel_mark_runs} stolen=#{h.parallel_mark_stolen}"
