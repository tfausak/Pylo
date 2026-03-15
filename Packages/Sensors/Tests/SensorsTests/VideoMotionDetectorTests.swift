import CoreVideo
import Testing

@testable import Sensors

@Suite struct VideoMotionDetectorTests {

  // MARK: - computeChangeRatio

  @Test func identicalFramesReturnZero() {
    let detector = VideoMotionDetector()
    let frame = [UInt8](repeating: 128, count: 160 * 120)
    let ratio = detector.computeChangeRatio(previous: frame, current: frame)
    #expect(ratio == 0)
  }

  @Test func completelyDifferentFramesReturnNearOne() {
    let detector = VideoMotionDetector()
    let black = [UInt8](repeating: 0, count: 160 * 120)
    let white = [UInt8](repeating: 255, count: 160 * 120)
    let ratio = detector.computeChangeRatio(previous: black, current: white)
    #expect(ratio > 0.99)
  }

  @Test func smallDifferenceBelowPixelThreshold() {
    let detector = VideoMotionDetector()
    // A difference of 10 per pixel → squared = 100, below pixel threshold of 625
    let a = [UInt8](repeating: 100, count: 160 * 120)
    let b = [UInt8](repeating: 110, count: 160 * 120)
    let ratio = detector.computeChangeRatio(previous: a, current: b)
    #expect(ratio == 0)
  }

  @Test func differencAbovePixelThreshold() {
    let detector = VideoMotionDetector()
    // A difference of 30 per pixel → squared = 900, above pixel threshold of 625
    let a = [UInt8](repeating: 100, count: 160 * 120)
    let b = [UInt8](repeating: 130, count: 160 * 120)
    let ratio = detector.computeChangeRatio(previous: a, current: b)
    #expect(ratio > 0.99)
  }

  @Test func partialChange() {
    let detector = VideoMotionDetector()
    let count = 160 * 120
    let a = [UInt8](repeating: 100, count: count)
    // Change first half by 30 (above threshold), leave second half unchanged
    var b = a
    for i in 0..<(count / 2) {
      b[i] = 130
    }
    let ratio = detector.computeChangeRatio(previous: a, current: b)
    // Should be approximately 0.5
    #expect(ratio > 0.45 && ratio < 0.55)
  }

  // MARK: - State machine

  @Test func firstFrameDoesNotTriggerMotion() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb = makePixelBuffer(gray: 128)!
    detector.processPixelBuffer(pb)

    #expect(motionEvents.isEmpty)
  }

  @Test func identicalFramesDoNotTriggerMotion() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb = makePixelBuffer(gray: 128)!
    detector.processPixelBuffer(pb)
    detector.processPixelBuffer(pb)
    detector.processPixelBuffer(pb)

    #expect(motionEvents.isEmpty)
  }

  @Test func differentFrameTriggersMotion() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb1 = makePixelBuffer(gray: 0)!
    let pb2 = makePixelBuffer(gray: 255)!
    detector.processPixelBuffer(pb1)
    detector.processPixelBuffer(pb2)

    #expect(motionEvents == [true])
  }

  @Test func motionNotRepeatedlyFired() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb1 = makePixelBuffer(gray: 0)!
    let pb2 = makePixelBuffer(gray: 255)!
    detector.processPixelBuffer(pb1)
    detector.processPixelBuffer(pb2)
    detector.processPixelBuffer(pb1)

    // Only one "detected" event, not two
    #expect(motionEvents == [true])
  }

  @Test func motionClearsAfterCooldown() {
    let detector = VideoMotionDetector()
    detector.cooldown = 0  // immediate cooldown for testing
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb1 = makePixelBuffer(gray: 0)!
    let pb2 = makePixelBuffer(gray: 255)!
    detector.processPixelBuffer(pb1)
    detector.processPixelBuffer(pb2)  // motion detected
    detector.processPixelBuffer(pb2)  // identical → should clear (cooldown=0)

    #expect(motionEvents == [true, false])
  }

  @Test func resetClearsState() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb1 = makePixelBuffer(gray: 0)!
    let pb2 = makePixelBuffer(gray: 255)!
    detector.processPixelBuffer(pb1)
    detector.processPixelBuffer(pb2)  // motion detected

    detector.reset()
    motionEvents.removeAll()

    // After reset, first frame again — no event
    detector.processPixelBuffer(pb1)
    #expect(motionEvents.isEmpty)
  }
}

// MARK: - Helpers

/// Create a 160×120 BGRA pixel buffer filled with a uniform gray value.
private func makePixelBuffer(gray: UInt8) -> CVPixelBuffer? {
  let width = 160
  let height = 120
  var pb: CVPixelBuffer?
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault, width, height,
    kCVPixelFormatType_32BGRA, nil, &pb)
  guard status == kCVReturnSuccess, let pb else { return nil }

  CVPixelBufferLockBaseAddress(pb, [])
  defer { CVPixelBufferUnlockBaseAddress(pb, []) }

  guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
  let rowBytes = CVPixelBufferGetBytesPerRow(pb)
  let ptr = base.assumingMemoryBound(to: UInt8.self)
  for y in 0..<height {
    for x in 0..<width {
      let offset = y * rowBytes + x * 4
      ptr[offset + 0] = gray  // B
      ptr[offset + 1] = gray  // G
      ptr[offset + 2] = gray  // R
      ptr[offset + 3] = 255   // A
    }
  }
  return pb
}
