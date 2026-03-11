import os

/// Drop-in replacement for `OSAllocatedUnfairLock` that works back to iOS 15.
/// Provides the same `withLock` and `withLockUnchecked` API.
public final class Locked<State>: @unchecked Sendable {
  private let _lock: os_unfair_lock_t
  private var _state: State

  public init(initialState: State) {
    _lock = .allocate(capacity: 1)
    _lock.initialize(to: os_unfair_lock())
    _state = initialState
  }

  deinit {
    _lock.deinitialize(count: 1)
    _lock.deallocate()
  }

  public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
    os_unfair_lock_lock(_lock)
    defer { os_unfair_lock_unlock(_lock) }
    return try body(&_state)
  }

  public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
    try withLock(body)
  }
}
