import os

/// Drop-in replacement for `OSAllocatedUnfairLock` that works back to iOS 15.
/// Provides the same `withLock` and `withLockUnchecked` API.
///
/// All methods are `@inlinable` so the compiler can specialize them at call
/// sites. Without inlining, closure types stored as the generic `State`
/// (e.g. `Locked<((Foo) -> Void)?>`) trigger a Swift reabstraction thunk
/// cycle: two thunks converting between `@in_guaranteed` and `@guaranteed`
/// calling conventions call each other in infinite mutual recursion,
/// overflowing the stack. Inlining lets the compiler see the concrete type
/// and eliminate the thunks.
public final class Locked<State>: @unchecked Sendable {
  @usableFromInline
  struct Buffer {
    @usableFromInline var lock = os_unfair_lock()
    @usableFromInline var state: State

    @usableFromInline
    init(lock: os_unfair_lock = os_unfair_lock(), state: State) {
      self.lock = lock
      self.state = state
    }
  }

  @usableFromInline
  let _buffer: UnsafeMutablePointer<Buffer>

  @inlinable
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

  @inlinable
  public func withLock<R: Sendable>(
    _ body: @Sendable (inout State) throws -> R
  ) rethrows -> R {
    os_unfair_lock_lock(&_buffer.pointee.lock)
    defer { os_unfair_lock_unlock(&_buffer.pointee.lock) }
    return try body(&_buffer.pointee.state)
  }

  @inlinable
  public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
    os_unfair_lock_lock(&_buffer.pointee.lock)
    defer { os_unfair_lock_unlock(&_buffer.pointee.lock) }
    return try body(&_buffer.pointee.state)
  }

  /// Direct locked access to the stored value (unchecked variant).
  ///
  /// Prefer this over `withLockUnchecked { $0 }` for simple get/set.
  /// The closure-based APIs introduce two generic boundaries (the closure
  /// parameter and its return value), which can trigger a Swift reabstraction
  /// thunk cycle — two thunks converting between indirect and direct calling
  /// conventions call each other in infinite mutual recursion. A property
  /// accessor has only one boundary (the return), making recursion impossible.
  @inlinable
  public var valueUnchecked: State {
    get {
      os_unfair_lock_lock(&_buffer.pointee.lock)
      defer { os_unfair_lock_unlock(&_buffer.pointee.lock) }
      return _buffer.pointee.state
    }
    set {
      os_unfair_lock_lock(&_buffer.pointee.lock)
      defer { os_unfair_lock_unlock(&_buffer.pointee.lock) }
      _buffer.pointee.state = newValue
    }
  }
}

extension Locked where State: Sendable {
  /// Direct locked access to the stored value (Sendable variant).
  ///
  /// Prefer this over `withLock { $0 }` for simple get/set. See
  /// `valueUnchecked` for the rationale on avoiding the closure-based APIs.
  @inlinable
  public var value: State {
    get { valueUnchecked }
    set { valueUnchecked = newValue }
  }
}
