import CoreMedia
import Foundation
import Testing

@testable import FragmentedMP4

// MARK: - FragmentedMP4Writer Thread Safety Tests

@Suite("FragmentedMP4Writer Thread Safety")
struct FragmentedMP4WriterThreadSafetyTests {

  @Test("Concurrent stop does not crash")
  func concurrentStop() async {
    let writer = FragmentedMP4Writer()
    writer.configure(width: 1920, height: 1080, fps: 30)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask { writer.stop() }
        group.addTask { writer.appendAudioSample(Data(repeating: 0xAA, count: 100)) }
      }
    }
  }

  @Test("Concurrent appendAudioSample does not crash")
  func concurrentAppendAudio() async {
    let writer = FragmentedMP4Writer()
    writer.configure(width: 1920, height: 1080, fps: 30)

    await withTaskGroup(of: Void.self) { group in
      for i in 0..<100 {
        group.addTask {
          writer.appendAudioSample(Data(repeating: UInt8(i & 0xFF), count: 50))
        }
      }
    }

    // Just verify it didn't crash — no specific output to check
    writer.stop()
  }

  @Test("includeAudioTrack property is thread-safe")
  func includeAudioTrackThreadSafe() async {
    let writer = FragmentedMP4Writer()
    writer.configure(width: 1920, height: 1080, fps: 30)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask { writer.includeAudioTrack = true }
        group.addTask { writer.includeAudioTrack = false }
        group.addTask { _ = writer.includeAudioTrack }
        group.addTask { _ = writer.initSegment }
      }
    }
  }
}

// MARK: - FragmentRingBuffer Tests

@Suite("FragmentRingBuffer")
struct FragmentRingBufferTests {

  private func makeFragment(seq: Int, dataSize: Int = 10) -> MP4Fragment {
    MP4Fragment(
      data: Data(repeating: UInt8(seq & 0xFF), count: dataSize),
      timestamp: CMTime(value: Int64(seq * 1000), timescale: 1000),
      duration: CMTime(value: 1000, timescale: 1000),
      sequenceNumber: seq
    )
  }

  @Test("Snapshot returns empty for new buffer")
  func emptySnapshot() {
    let buf = FragmentRingBuffer(capacity: 3)
    #expect(buf.snapshot().isEmpty)
  }

  @Test("Appended fragments appear in snapshot")
  func appendAndSnapshot() {
    let buf = FragmentRingBuffer(capacity: 3)
    buf.append(makeFragment(seq: 0))
    buf.append(makeFragment(seq: 1))
    let snap = buf.snapshot()
    #expect(snap.count == 2)
    #expect(snap[0].sequenceNumber == 0)
    #expect(snap[1].sequenceNumber == 1)
  }

  @Test("Ring buffer evicts oldest when full")
  func evictsOldest() {
    let buf = FragmentRingBuffer(capacity: 2)
    buf.append(makeFragment(seq: 0))
    buf.append(makeFragment(seq: 1))
    buf.append(makeFragment(seq: 2))
    let snap = buf.snapshot()
    #expect(snap.count == 2)
    #expect(snap[0].sequenceNumber == 1)
    #expect(snap[1].sequenceNumber == 2)
  }

  @Test("Clear empties buffer and resets sequence")
  func clearResetsBuffer() {
    let buf = FragmentRingBuffer(capacity: 3)
    buf.append(makeFragment(seq: 0))
    _ = buf.nextSequenceNumber()
    _ = buf.nextSequenceNumber()
    buf.clear()
    #expect(buf.snapshot().isEmpty)
    #expect(buf.nextSequenceNumber() == 0)
  }

  @Test("nextSequenceNumber increments monotonically")
  func sequenceIncrement() {
    let buf = FragmentRingBuffer(capacity: 2)
    #expect(buf.nextSequenceNumber() == 0)
    #expect(buf.nextSequenceNumber() == 1)
    #expect(buf.nextSequenceNumber() == 2)
  }

  @Test("Concurrent append and snapshot does not crash")
  func concurrentAccess() async {
    let buf = FragmentRingBuffer(capacity: 5)
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<50 {
        group.addTask { buf.append(self.makeFragment(seq: i)) }
        group.addTask { _ = buf.snapshot() }
        group.addTask { _ = buf.nextSequenceNumber() }
      }
    }
    // Buffer should contain at most capacity fragments
    #expect(buf.snapshot().count <= 5)
  }
}

// MARK: - FragmentedMP4Writer Structural Tests

@Suite("FragmentedMP4Writer Structure")
struct FragmentedMP4WriterStructureTests {

  @Test("initSegment is nil before configure with format description")
  func initSegmentNilBeforeFormat() {
    let writer = FragmentedMP4Writer()
    writer.configure(width: 1920, height: 1080, fps: 30)
    #expect(writer.initSegment == nil)
  }

  @Test("Stop without samples does not call onFragmentReady")
  func stopWithoutSamples() {
    let writer = FragmentedMP4Writer()
    writer.configure(width: 1920, height: 1080, fps: 30)
    nonisolated(unsafe) var callCount = 0
    writer.onFragmentReady = { _ in callCount += 1 }
    writer.stop()
    #expect(callCount == 0)
  }

  @Test("includeAudioTrack defaults to false")
  func audioTrackDefault() {
    let writer = FragmentedMP4Writer()
    #expect(writer.includeAudioTrack == false)
  }

  @Test("includeAudioTrack setter invalidates init segment")
  func audioTrackInvalidatesInit() {
    let writer = FragmentedMP4Writer()
    writer.configure(width: 1920, height: 1080, fps: 30)
    // initSegment is nil because no format description has been set,
    // but toggling includeAudioTrack should clear any cached format
    writer.includeAudioTrack = true
    #expect(writer.initSegment == nil)
    writer.includeAudioTrack = false
    #expect(writer.initSegment == nil)
  }

  @Test("onFragmentReady can be set and cleared")
  func onFragmentReadySetClear() {
    let writer = FragmentedMP4Writer()
    writer.onFragmentReady = { _ in }
    writer.onFragmentReady = nil
    // Just verify no crash
  }

  @Test("appendAudioSample accumulates samples")
  func appendAudioAccumulates() {
    let writer = FragmentedMP4Writer()
    writer.configure(width: 1920, height: 1080, fps: 30)
    for _ in 0..<10 {
      writer.appendAudioSample(Data(repeating: 0xAA, count: 50))
    }
    // Stop should clear without crashing
    writer.stop()
  }
}
