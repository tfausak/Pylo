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
