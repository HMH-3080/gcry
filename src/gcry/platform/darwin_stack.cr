require "c/pthread"

module Gcry
  # Darwin pthread stack bounds (for STW root scanning / main-fiber setup).
  module Platform
    # Returns {stack_low, stack_high} for *thread*, or nil on failure.
    # *stack_high* is the exclusive top (stack grows down toward *stack_low*).
    # Darwin: pthread_get_stackaddr_np returns the high address.
    def self.pthread_stack_bounds(thread : LibC::PthreadT) : {Void*, Void*}?
      {% if flag?(:darwin) %}
        addr = LibC.pthread_get_stackaddr_np(thread)
        size = LibC.pthread_get_stacksize_np(thread)
        return nil if addr.null? || size == 0

        high = addr
        low = Pointer(Void).new(addr.address - size.to_u64)
        {low, high}
      {% else %}
        nil
      {% end %}
    end

    def self.current_pthread_stack_bounds : {Void*, Void*}?
      {% if flag?(:darwin) %}
        pthread_stack_bounds(LibC.pthread_self)
      {% else %}
        nil
      {% end %}
    end

    # Same API as the Linux snapshot, and the same reason, reached late.
    # `pthread_get_stackaddr_np` on a thread other than the caller validates it
    # under libpthread's global list lock, which a suspended thread can hold
    # for the whole stop. So during a stop the bounds come from the table the
    # stop resolved before suspending anyone (`darwin_stw.cr`), and a thread
    # that is not in it has none. Outside a stop the lookup is direct.
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

    def self.snapshot_pthread_stack_bounds(thread : LibC::PthreadT) : Nil
    end

    def self.snapshotted_stack_bounds(thread : LibC::PthreadT) : {Void*, Void*}?
      {% if flag?(:darwin) %}
        return stop_stack_bounds(thread) if stop_active?
      {% end %}
      pthread_stack_bounds(thread)
    end

    def self.stack_bounds_snapshot_misses : UInt64
      {% if flag?(:darwin) %}
        stop_bounds_misses
      {% else %}
        0_u64
      {% end %}
    end

    # The stop table grows with the thread list and cannot run out. Zero
    # rather than a missing method: a caller that gates on this must not have
    # to ask which platform it is on.
    def self.stack_bounds_capacity_misses : UInt64
      0_u64
    end

    def self.stack_bounds_nogrow=(value : Bool) : Bool
      value
    end

    # The stop resolves every thread's bounds in its own walk, in
    # `darwin_stw.cr`, not through Linux's visit/read snapshot, so there is no
    # visit/read pair to count and nothing is ever in flight. Zeros rather
    # than a missing method: a caller that gates on these must not have to ask
    # which platform it is on.
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
