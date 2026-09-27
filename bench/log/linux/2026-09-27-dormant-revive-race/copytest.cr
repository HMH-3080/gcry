struct T
  property freelists : StaticArray(Int32, 4)
  property live : Bool

  def initialize
    @freelists = StaticArray(Int32, 4).new(0)
    @live = true
  end
end

class H
  @tlabs : StaticArray(T, 2)

  def initialize
    @tlabs = StaticArray(T, 2).new { T.new }
  end

  def via_index
    @tlabs[0].freelists[1] = 7
    @tlabs[0].freelists[1]
  end

  def via_pointer
    p = @tlabs.to_unsafe + 1
    p.value.freelists[1] = 9
    p.value.freelists[1]
  end
end

class H
  def live_via_index
    @tlabs[0].live = false
    @tlabs[0].live
  end

  def live_via_pointer
    p = @tlabs.to_unsafe
    p.value.live = false
    p.value.live
  end
end

h = H.new
puts "via @tlabs[i].freelists[c] = : #{h.via_index}"
puts "via ptr.value.freelists[c] = : #{h.via_pointer}"
puts "live via index (want false): #{h.live_via_index}"
puts "live via pointer (want false): #{h.live_via_pointer}"
