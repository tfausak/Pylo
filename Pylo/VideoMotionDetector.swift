import Accelerate
import CoreVideo
import os

/// Detects motion by comparing consecutive video frames using vImage.
/// Downscales each frame to a small grayscale thumbnail and computes the
/// sum of squared differences against the previous frame.
nonisolated final class VideoMotionDetector {

  private let _onMotionChange = OSAllocatedUnfairLock<((Bool) -> Void)?>(initialState: nil)
  var onMotionChange: ((Bool) -> Void)? {
    get { _onMotionChange.withLock { $0 } }
    set { _onMotionChange.withLock { $0 = newValue } }
  }

  /// Fraction of pixels that must differ to trigger motion (0.0–1.0).
  var threshold: Float {
    get { state.withLock { $0.threshold } }
    set { state.withLock { $0.threshold = newValue } }
  }

  /// Seconds of calm required before reporting no motion.
  var cooldown: TimeInterval {
    get { state.withLock { $0.cooldown } }
    set { state.withLock { $0.cooldown = newValue } }
  }

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "VideoMotion")

  // Target thumbnail dimensions for comparison
  private static let thumbWidth = 160
  private static let thumbHeight = 120

  // Thread-safe mutable state
  private struct State {
    var isMotionDetected = false
    var lastMotionDate = Date.distantPast
    var threshold: Float = 0.05
    var cooldown: TimeInterval = 3.0
    var previousFrame: [UInt8]?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  // Pre-allocated buffers for vDSP frame comparison (avoids per-frame heap allocation).
  // Thread safety: these are only accessed from processPixelBuffer → computeChangeRatio,
  // which must be called from a single serial queue (the capture queue). They are NOT
  // protected by the lock to avoid overhead on every video frame. The caller must ensure
  // that only one capture session is active at a time.
  private var prevFloat: [Float]
  private var currFloat: [Float]
  private var diff: [Float]

  init() {
    let n = Self.thumbWidth * Self.thumbHeight
    prevFloat = [Float](repeating: 0, count: n)
    currFloat = [Float](repeating: 0, count: n)
    diff = [Float](repeating: 0, count: n)
  }

  /// Process a pixel buffer for motion detection.
  /// Must be called from a single serial queue — the vDSP scratch buffers are not
  /// lock-protected, so concurrent calls would cause data races.
  func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    let grayscale = downsampleToGrayscale(pixelBuffer)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    guard let grayscale else { return }

    let previous = state.withLock { s -> [UInt8]? in
      let prev = s.previousFrame
      s.previousFrame = grayscale
      return prev
    }

    guard let previous else { return }

    let changeRatio = computeChangeRatio(previous: previous, current: grayscale)

    if changeRatio > threshold {
      let shouldNotify = state.withLock { state in
        state.lastMotionDate = Date()
        if !state.isMotionDetected {
          state.isMotionDetected = true
          return true
        }
        return false
      }
      if shouldNotify {
        logger.debug(
          "Video motion detected (change=\(changeRatio, format: .fixed(precision: 4)))"
        )
        onMotionChange?(true)
      }
    } else {
      let elapsed: TimeInterval? = state.withLock { state in
        guard state.isMotionDetected else { return nil }
        let elapsed = Date().timeIntervalSince(state.lastMotionDate)
        if elapsed >= state.cooldown {
          state.isMotionDetected = false
          return elapsed
        }
        return nil
      }
      if let elapsed {
        logger.debug(
          "Video motion cleared after \(elapsed, format: .fixed(precision: 1))s"
        )
        onMotionChange?(false)
      }
    }
  }

  /// Reset state (call when stopping detection).
  func reset() {
    state.withLock { state in
      state.previousFrame = nil
      state.isMotionDetected = false
      state.lastMotionDate = .distantPast
    }
  }

  // MARK: - Frame Processing

  /// Downsample a pixel buffer to a small grayscale image.
  private func downsampleToGrayscale(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
    let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
    let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

    // Handle both common video pixel formats
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      // NV12/NV21 — the Y plane is already grayscale
      guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
      let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
      return downsample(
        base: yBase, width: srcWidth, height: srcHeight, rowBytes: yRowBytes, bytesPerPixel: 1,
        channelOffset: 0)

    case kCVPixelFormatType_32BGRA:
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
      let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
      // BGRA: approximate grayscale by sampling the green channel (offset 1)
      return downsample(
        base: base, width: srcWidth, height: srcHeight, rowBytes: rowBytes, bytesPerPixel: 4,
        channelOffset: 1)

    default:
      return nil
    }
  }

  /// Simple nearest-neighbor downsample to thumbWidth x thumbHeight.
  private func downsample(
    base: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int,
    bytesPerPixel: Int, channelOffset: Int
  ) -> [UInt8] {
    let tw = Self.thumbWidth
    let th = Self.thumbHeight
    var result = [UInt8](repeating: 0, count: tw * th)

    for ty in 0..<th {
      let sy = ty * height / th
      let srcRow = base + sy * rowBytes
      for tx in 0..<tw {
        let sx = tx * width / tw
        result[ty * tw + tx] = srcRow.load(
          fromByteOffset: sx * bytesPerPixel + channelOffset, as: UInt8.self)
      }
    }

    return result
  }

  /// Compute the fraction of pixels that differ significantly between frames.
  private func computeChangeRatio(previous: [UInt8], current: [UInt8]) -> Float {
    let count = min(previous.count, current.count)
    guard count > 0 else { return 0 }

    // Use pre-allocated buffers for vDSP comparison
    vDSP.convertElements(of: previous[0..<count], to: &prevFloat)
    vDSP.convertElements(of: current[0..<count], to: &currFloat)

    // Squared difference
    vDSP.subtract(prevFloat, currFloat, result: &diff)
    vDSP.square(diff, result: &diff)

    // Count pixels where squared difference exceeds threshold (e.g., 25^2 = 625)
    // A pixel value change of 25 out of 255 is considered significant.
    // Use vDSP to vectorize: subtract threshold, clip negatives to 0,
    // then count non-zero entries.
    let pixelThreshold: Float = 625.0
    var negThreshold = -pixelThreshold
    vDSP_vsadd(diff, 1, &negThreshold, &diff, 1, vDSP_Length(count))
    var lo: Float = 0
    var hi: Float = 1.0
    // Clip to [0, 1] — below-threshold → 0, above-threshold → 1
    vDSP_vclip(diff, 1, &lo, &hi, &diff, 1, vDSP_Length(count))
    // Sum the 0/1 vector to get the count of changed pixels
    var changedCount: Float = 0
    vDSP_sve(diff, 1, &changedCount, vDSP_Length(count))

    return changedCount / Float(count)
  }
}
