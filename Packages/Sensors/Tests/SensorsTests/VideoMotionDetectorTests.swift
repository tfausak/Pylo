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

  // MARK: - NV12 format

  @Test func nv12IdenticalFramesDoNotTriggerMotion() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb = makeNV12PixelBuffer(width: 640, height: 480, yValue: 128)!
    detector.processPixelBuffer(pb)
    detector.processPixelBuffer(pb)

    #expect(motionEvents.isEmpty)
  }

  @Test func nv12DifferentFrameTriggersMotion() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb1 = makeNV12PixelBuffer(width: 640, height: 480, yValue: 0)!
    let pb2 = makeNV12PixelBuffer(width: 640, height: 480, yValue: 255)!
    detector.processPixelBuffer(pb1)
    detector.processPixelBuffer(pb2)

    #expect(motionEvents == [true])
  }

  // MARK: - Larger source dimensions (actual downscaling)

  @Test func largerBGRAFrameTriggersMotion() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb1 = makeBGRAPixelBuffer(width: 1920, height: 1080, gray: 0)!
    let pb2 = makeBGRAPixelBuffer(width: 1920, height: 1080, gray: 255)!
    detector.processPixelBuffer(pb1)
    detector.processPixelBuffer(pb2)

    #expect(motionEvents == [true])
  }

  @Test func largerBGRAIdenticalFramesNoMotion() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb = makeBGRAPixelBuffer(width: 1920, height: 1080, gray: 128)!
    detector.processPixelBuffer(pb)
    detector.processPixelBuffer(pb)

    #expect(motionEvents.isEmpty)
  }

  @Test func largerNV12FrameTriggersMotion() {
    let detector = VideoMotionDetector()
    var motionEvents: [Bool] = []
    detector.onMotionChange = { motionEvents.append($0) }

    let pb1 = makeNV12PixelBuffer(width: 1280, height: 720, yValue: 0)!
    let pb2 = makeNV12PixelBuffer(width: 1280, height: 720, yValue: 255)!
    detector.processPixelBuffer(pb1)
    detector.processPixelBuffer(pb2)

    #expect(motionEvents == [true])
  }
}

// MARK: - Helpers

/// Create a BGRA pixel buffer filled with a uniform gray value.
/// Defaults to 160×120 (matching thumb dimensions) for basic tests.
private func makePixelBuffer(gray: UInt8) -> CVPixelBuffer? {
  makeBGRAPixelBuffer(width: 160, height: 120, gray: gray)
}

private func makeBGRAPixelBuffer(width: Int, height: Int, gray: UInt8) -> CVPixelBuffer? {
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

/// Create an NV12 (bi-planar YCbCr) pixel buffer with a uniform Y value.
private func makeNV12PixelBuffer(width: Int, height: Int, yValue: UInt8) -> CVPixelBuffer? {
  var pb: CVPixelBuffer?
  let attrs: [String: Any] = [
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
  ]
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault, width, height,
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    attrs as CFDictionary, &pb)
  guard status == kCVReturnSuccess, let pb else { return nil }

  CVPixelBufferLockBaseAddress(pb, [])
  defer { CVPixelBufferUnlockBaseAddress(pb, []) }

  // Fill Y plane
  guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
  let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
  let yHeight = CVPixelBufferGetHeightOfPlane(pb, 0)
  let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
  for row in 0..<yHeight {
    memset(yPtr + row * yRowBytes, Int32(yValue), width)
  }

  // Fill CbCr plane with neutral chroma (128)
  guard let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
  let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
  let uvHeight = CVPixelBufferGetHeightOfPlane(pb, 1)
  let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)
  for row in 0..<uvHeight {
    memset(uvPtr + row * uvRowBytes, 128, width)
  }

  return pb
}
