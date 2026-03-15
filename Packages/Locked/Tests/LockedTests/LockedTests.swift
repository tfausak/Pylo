import Foundation
import Locked
import Testing

@Suite("Locked")
struct LockedTests {

  @Test("Initial state is accessible")
  func initialState() {
    let locked = Locked(initialState: 42)
    let value = locked.withLock { $0 }
    #expect(value == 42)
  }

  @Test("Mutation persists")
  func mutation() {
    let locked = Locked(initialState: 0)
    locked.withLock { $0 = 99 }
    #expect(locked.withLock { $0 } == 99)
  }

  @Test("withLock returns a value")
  func returnValue() {
    let locked = Locked(initialState: [1, 2, 3])
    let count = locked.withLock { $0.count }
    #expect(count == 3)
  }

  @Test("withLock propagates throws")
  func propagatesThrows() {
    struct TestError: Error {}
    let locked = Locked(initialState: 0)
    #expect(throws: TestError.self) {
      try locked.withLock { _ in throw TestError() }
    }
  }

  @Test("State reflects partial mutation after throw")
  func throwMidMutation() {
    struct E: Error {}
    let locked = Locked(initialState: 0)
    try? locked.withLock { state in
      state = 42
      throw E()
    }
    #expect(locked.withLock { $0 } == 42)
  }

  @Test("withLockUnchecked returns non-Sendable values")
  func uncheckedReturn() {
    // NSObject is non-Sendable — withLockUnchecked allows returning it.
    // withLock would reject this at compile time due to its Sendable constraints.
    let locked = Locked(initialState: NSObject())
    let obj = locked.withLockUnchecked { $0 }
    #expect(obj is NSObject)
  }
}

@Suite("Locked Thread Safety")
struct LockedThreadSafetyTests {

  @Test("Concurrent increments produce correct total")
  func concurrentIncrements() async {
    let locked = Locked(initialState: 0)
    let iterations = 1000

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<iterations {
        group.addTask {
          locked.withLock { $0 += 1 }
        }
      }
    }

    #expect(locked.withLock { $0 } == iterations)
  }

  @Test("Concurrent reads and writes do not crash")
  func concurrentReadWrite() async {
    let locked = Locked(initialState: [Int]())

    await withTaskGroup(of: Void.self) { group in
      // Writers
      for i in 0..<100 {
        group.addTask {
          locked.withLock { $0.append(i) }
        }
      }
      // Readers
      for _ in 0..<100 {
        group.addTask {
          _ = locked.withLock { $0.count }
        }
      }
    }

    #expect(locked.withLock { $0.count } == 100)
  }
}
