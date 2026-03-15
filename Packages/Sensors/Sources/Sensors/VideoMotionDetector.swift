import Accelerate
import CoreVideo
import Locked
import os

/// Detects motion by comparing consecutive video frames using vImage.
/// Downscales each frame to a small grayscale thumbnail and computes the
/// sum of squared differences against the previous frame.
public nonisolated final class VideoMotionDetector {

  private let _onMotionChange = Locked<((Bool) -> Void)?>(initialState: nil)
  public var onMotionChange: ((Bool) -> Void)? {
    get { _onMotionChange.withLockUnchecked { $0 } }
    set { _onMotionChange.withLockUnchecked { $0 = newValue } }
  }

  /// Fraction of pixels that must differ to trigger motion (0.0–1.0).
  public var threshold: Float {
    get { state.withLockUnchecked { $0.threshold } }
    set { state.withLockUnchecked { $0.threshold = newValue } }
  }

  /// Seconds of calm required before reporting no motion.
  public var cooldown: TimeInterval {
    get { state.withLockUnchecked { $0.cooldown } }
    set { state.withLockUnchecked { $0.cooldown = newValue } }
  }

  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sensors", category: "VideoMotion")

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

  private let state = Locked(initialState: State())

  /// Debug-only flag to detect concurrent calls to processPixelBuffer.
  /// Scratch buffers are reused across calls and must not be accessed concurrently.
  private let _processing = Locked(initialState: false)

  public init() {}

  /// Process a pixel buffer for motion detection.
  /// Safe to call from any queue — all mutable state is lock-protected.
  /// Must not be called concurrently; scratch buffers are reused across calls.
  /// Caller is responsible for throttling (e.g., calling every Nth frame).
  public func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
    // Guard against concurrent entry — scratch buffers are not thread-safe.
    // Uses a real lock guard (not just assert) so it works in release builds.
    guard
      _processing.withLockUnchecked({ p in
        guard !p else { return false }
        p = true
        return true
      })
    else {
      logger.warning("processPixelBuffer called concurrently — skipping frame")
      return
    }
    defer { _processing.withLockUnchecked { $0 = false } }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    let ok = downsampleToGrayscale(pixelBuffer)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    guard ok else { return }

    // Get the previous frame without swapping yet, so scratchGray is
    // exclusively ours during computeChangeRatio (no aliasing with state).
    let previous = state.withLockUnchecked { $0.previousFrame }

    guard let previous else {
      // First frame — stash it for comparison on the next call.
      state.withLockUnchecked { $0.previousFrame = scratchGray }
      scratchGray = [UInt8](repeating: 0, count: Self.scratchCount)
      return
    }

    let changeRatio = computeChangeRatio(previous: previous, current: scratchGray)

    // Swap: store current frame as previousFrame, reclaim old buffer for reuse.
    state.withLockUnchecked { $0.previousFrame = scratchGray }
    scratchGray = previous

    if changeRatio > threshold {
      let shouldNotify = state.withLockUnchecked { state in
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
      let elapsed: TimeInterval? = state.withLockUnchecked { state in
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
  public func reset() {
    state.withLockUnchecked { state in
      state.previousFrame = nil
      state.isMotionDetected = false
      state.lastMotionDate = .distantPast
    }
  }

  // MARK: - Frame Processing

  /// Downsample a pixel buffer to a small grayscale image, writing into `scratchGray`.
  /// Returns false if the pixel format is unsupported.
  private func downsampleToGrayscale(_ pixelBuffer: CVPixelBuffer) -> Bool {
    let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
    let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let tw = Self.thumbWidth
    let th = Self.thumbHeight

    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      // NV12 — the Y plane is already planar 8-bit grayscale; stride-sample
      // nearest-neighbor (no interpolation needed for motion detection)
      guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return false }
      let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
      let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
      scratchGray.withUnsafeMutableBufferPointer { dst in
        for ty in 0..<th {
          let srcRowStart = (ty * srcHeight / th) * yRowBytes
          for tx in 0..<tw {
            dst[ty * tw + tx] = yPtr[srcRowStart + (tx * srcWidth / tw)]
          }
        }
      }
      return true

    case kCVPixelFormatType_32BGRA:
      // BGRA fallback: nearest-neighbor sampling the green channel (offset 1)
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
      let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
      for ty in 0..<th {
        let srcRow = base + (ty * srcHeight / th) * rowBytes
        for tx in 0..<tw {
          scratchGray[ty * tw + tx] = srcRow.load(
            fromByteOffset: (tx * srcWidth / tw) * 4 + 1, as: UInt8.self)
        }
      }
      return true

    default:
      return false
    }
  }

  // Reusable scratch buffers — avoids heap allocations per processed frame.
  // Accessed only from processPixelBuffer which has a concurrency guard.
  private static let scratchCount = thumbWidth * thumbHeight
  private var scratchGray = [UInt8](repeating: 0, count: scratchCount)
  private var scratchPrev = [Float](repeating: 0, count: scratchCount)
  private var scratchCurr = [Float](repeating: 0, count: scratchCount)
  private var scratchDiff = [Float](repeating: 0, count: scratchCount)

  /// Compute the fraction of pixels that differ significantly between frames.
  /// Mutates scratch buffers in place — caller must ensure no concurrent access.
  func computeChangeRatio(previous: [UInt8], current: [UInt8]) -> Float {
    let count = min(previous.count, current.count)
    guard count > 0, count <= Self.scratchCount else { return 0 }

    vDSP.convertElements(of: previous, to: &scratchPrev)
    vDSP.convertElements(of: current, to: &scratchCurr)

    // Squared difference
    vDSP.subtract(scratchPrev, scratchCurr, result: &scratchDiff)
    vDSP.square(scratchDiff, result: &scratchDiff)

    // Count pixels where squared difference exceeds threshold (e.g., 25^2 = 625)
    // A pixel value change of 25 out of 255 is considered significant.
    // Use vDSP to vectorize: subtract threshold, clip negatives to 0,
    // then count non-zero entries.
    let pixelThreshold: Float = 625.0
    var negThreshold = -pixelThreshold
    vDSP_vsadd(scratchDiff, 1, &negThreshold, &scratchDiff, 1, vDSP_Length(count))
    var lo: Float = 0
    var hi: Float = 1.0
    // Clip to [0, 1] — below-threshold → 0, above-threshold → 1
    vDSP_vclip(scratchDiff, 1, &lo, &hi, &scratchDiff, 1, vDSP_Length(count))
    // Sum the 0/1 vector to get the count of changed pixels
    var changedCount: Float = 0
    vDSP_sve(scratchDiff, 1, &changedCount, vDSP_Length(count))

    return changedCount / Float(count)
  }
}
