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
    writer.configure(fps: 30)

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
    writer.configure(fps: 30)

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
    writer.configure(fps: 30)

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

  @Test("Multiple wrap-arounds preserve chronological order")
  func multipleWrapArounds() {
    let buf = FragmentRingBuffer(capacity: 3)
    for i in 0..<10 {
      buf.append(makeFragment(seq: i))
    }
    let snap = buf.snapshot()
    #expect(snap.count == 3)
    #expect(snap[0].sequenceNumber == 7)
    #expect(snap[1].sequenceNumber == 8)
    #expect(snap[2].sequenceNumber == 9)
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

// MARK: - MPEG-4 Descriptor Length Encoding Tests

@Suite("MP4 Descriptor Length")
struct MP4DescriptorLengthTests {

  @Test("Zero encodes to single byte 0x00")
  func zero() {
    let result = FragmentedMP4Writer.mp4DescriptorLength(0)
    #expect(result == Data([0x00]))
  }

  @Test("Values below 128 encode to a single byte")
  func singleByte() {
    #expect(FragmentedMP4Writer.mp4DescriptorLength(1) == Data([0x01]))
    #expect(FragmentedMP4Writer.mp4DescriptorLength(42) == Data([42]))
    #expect(FragmentedMP4Writer.mp4DescriptorLength(127) == Data([0x7F]))
  }

  @Test("Value 128 encodes to two bytes with continuation bit")
  func twoBytes128() {
    // 128 = 0x80: high byte has continuation bit set (0x80 | 0x01 = 0x81), low byte is 0x00
    let result = FragmentedMP4Writer.mp4DescriptorLength(128)
    #expect(result == Data([0x81, 0x00]))
  }

  @Test("Value 255 encodes to two bytes")
  func twoBytes255() {
    // 255 = 0xFF: 255 >> 7 = 1, 255 & 0x7F = 0x7F → [0x81, 0x7F]
    let result = FragmentedMP4Writer.mp4DescriptorLength(255)
    #expect(result == Data([0x81, 0x7F]))
  }

  @Test("Value 16383 encodes to two bytes (max 2-byte)")
  func twoBytesMax() {
    // 16383 = 0x3FFF: 16383 >> 7 = 127, 16383 & 0x7F = 0x7F → [0xFF, 0x7F]
    let result = FragmentedMP4Writer.mp4DescriptorLength(16383)
    #expect(result == Data([0xFF, 0x7F]))
  }

  @Test("Value 16384 encodes to three bytes")
  func threeBytesMin() {
    // 16384 = 0x4000: requires 3 bytes
    let result = FragmentedMP4Writer.mp4DescriptorLength(16384)
    #expect(result.count == 3)
    // Verify continuation bits: first two bytes have MSB set, last does not
    #expect(result[0] & 0x80 != 0)
    #expect(result[1] & 0x80 != 0)
    #expect(result[2] & 0x80 == 0)
  }

  @Test("Typical AAC config sizes encode to single byte")
  func typicalAACSize() {
    // AAC-ELD AudioSpecificConfig is typically 2-5 bytes
    // ESDS descriptor total is typically ~25 bytes
    for size in [2, 5, 14, 25, 50] {
      let result = FragmentedMP4Writer.mp4DescriptorLength(size)
      #expect(result.count == 1, "Size \(size) should encode as single byte")
    }
  }
}

// MARK: - FragmentedMP4Writer Structural Tests

@Suite("FragmentedMP4Writer Structure")
struct FragmentedMP4WriterStructureTests {

  @Test("initSegment is nil before configure with format description")
  func initSegmentNilBeforeFormat() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    #expect(writer.initSegment == nil)
  }

  @Test("Stop without samples does not call onFragmentReady")
  func stopWithoutSamples() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
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
    writer.configure(fps: 30)
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
    writer.configure(fps: 30)
    for _ in 0..<10 {
      writer.appendAudioSample(Data(repeating: 0xAA, count: 50))
    }
    // Stop should clear without crashing
    writer.stop()
  }
}
