import os

/// Drop-in replacement for `OSAllocatedUnfairLock` that works back to iOS 15.
/// Provides the same `withLock` and `withLockUnchecked` API.
public final class Locked<State>: @unchecked Sendable {
  private struct Buffer {
    var lock = os_unfair_lock()
    var state: State
  }

  private let _buffer: UnsafeMutablePointer<Buffer>

  public init(initialState: State) {
    _buffer = .allocate(capacity: 1)
    _buffer.initialize(to: Buffer(state: initialState))
  }

  // Leak detection for this manual allocation is not unit-testable from Swift;
  // use Instruments (Leaks/Allocations) or Address Sanitizer to verify.
  deinit {
    _buffer.deinitialize(count: 1)
    _buffer.deallocate()
  }

  public func withLock<R: Sendable>(
    _ body: @Sendable (inout State) throws -> R
  ) rethrows -> R {
    os_unfair_lock_lock(&_buffer.pointee.lock)
    defer { os_unfair_lock_unlock(&_buffer.pointee.lock) }
    return try body(&_buffer.pointee.state)
  }

  public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
    os_unfair_lock_lock(&_buffer.pointee.lock)
    defer { os_unfair_lock_unlock(&_buffer.pointee.lock) }
    return try body(&_buffer.pointee.state)
  }
}
