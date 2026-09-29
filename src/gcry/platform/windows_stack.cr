module Gcry
  module Platform
    def self.current_pthread_stack_bounds : {Void*, Void*}?
      LibC.GetCurrentThreadStackLimits(out low, out high)
      {Pointer(Void).new(low), Pointer(Void).new(high)}
    end

    # Crystal's record of a thread's stack is its main fiber, and a starting
    # thread is on `Thread.threads` before it has one: `Thread#start` pushes
    # itself, then runs `Fiber.new(stack_address, self)`, which allocates the
    # fiber and only at its end pushes it onto the fiber list. A thread stopped
    # in between had no bounds here, so its stack was not scanned at all — and
    # the new `Fiber` was on that stack and nowhere else. The sweep freed it,
    # the push published the freed block, and the next fiber walk read it:
    # `Fiber#running?` at C0000005 on a decommitted page in `make tls-roots`
    # on the Windows default job, 3 runs in 100; `bench/thread_birth_fiber.cr`
    # lost 9 fibers in 3 000 births before this and 0 after
    # (`bench/log/linux/2026-09-29-windows-unborn-thread-stack/FINDINGS.md`).
    #
    # So a listed thread with no main fiber is bounded by the OS instead: the
    # reservation its suspend SP lies in, which is the thread's stack.
    def self.pthread_stack_bounds(handle : LibC::HANDLE) : {Void*, Void*}?
      Thread.unsafe_each do |thread|
        next unless thread.to_unsafe == handle
        if fiber = thread.@main_fiber
          stack = fiber.@stack
          return {stack.pointer.as(Void*), stack.bottom.as(Void*)}
        end
        return unborn_stack_bounds(handle)
      end
      nil
    end

    @@unborn_stack_bounds = 0_u64

    # Threads bounded by `unborn_stack_bounds` over the life of the process.
    def self.unborn_stack_bounds_total : UInt64
      @@unborn_stack_bounds
    end

    # `[AllocationBase, top)` of the reservation holding the SP captured at
    # suspend — what `GetCurrentThreadStackLimits` would answer on the thread
    # itself. The committed stack is reported as several regions with the same
    # allocation base (see `dead_stack_floor`), so the top is found by walking
    # up until the base changes. Nil outside a stop, where there is no SP.
    private def self.unborn_stack_bounds(handle : LibC::HANDLE) : {Void*, Void*}?
      sp = thread_sp(handle)
      return nil unless sp
      return nil if LibC.VirtualQuery(sp, out info, sizeof(LibC::MEMORY_BASIC_INFORMATION)) == 0
      alloc = info.allocationBase
      return nil if alloc.null? || info.state != LibC::MEM_COMMIT
      top = info.baseAddress.address &+ info.regionSize.to_u64
      64.times do
        break if LibC.VirtualQuery(Pointer(Void).new(top), out next_info, sizeof(LibC::MEMORY_BASIC_INFORMATION)) == 0
        break unless next_info.allocationBase == alloc
        top = next_info.baseAddress.address &+ next_info.regionSize.to_u64
      end
      @@unborn_stack_bounds &+= 1
      {alloc, Pointer(Void).new(top)}
    end

    # Crystal records each thread's stack bounds at startup, so suspended
    # threads need no OS query or allocating snapshot.
    def self.begin_stack_bounds_snapshot : Nil
    end

    # Linux caches the initial thread's bounds; here every lookup is direct.
    def self.note_main_thread : Nil
    end

    def self.reset_main_thread_after_fork : Nil
    end

    def self.stack_bounds_main_cached : UInt64
      0_u64
    end

    def self.stack_bounds_main_refreshed : UInt64
      0_u64
    end

    def self.snapshot_pthread_stack_bounds(thread : LibC::HANDLE) : Nil
    end

    def self.snapshotted_stack_bounds(thread : LibC::HANDLE) : {Void*, Void*}?
      pthread_stack_bounds(thread)
    end

    def self.stack_bounds_snapshot_misses : UInt64
      0_u64
    end

    # There is no table to run out of, for the same reason there is nothing to
    # snapshot. Zero rather than a missing method: a caller that gates on this
    # must not have to ask which platform it is on.
    def self.stack_bounds_capacity_misses : UInt64
      0_u64
    end

    def self.stack_bounds_nogrow=(value : Bool) : Bool
      value
    end

    def self.stack_bounds_visited : UInt64
      0_u64
    end

    def self.stack_bounds_read : UInt64
      0_u64
    end

    def self.stack_bounds_in_flight : UInt64
      0_u64
    end

    def self.stack_bounds_seen_before?(id : UInt64) : Bool
      false
    end

    def self.stack_bounds_seen_full? : Bool
      false
    end
  end
end
