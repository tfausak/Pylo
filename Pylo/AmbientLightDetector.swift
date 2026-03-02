import AVFoundation
import os

/// Estimates ambient light level (lux) from camera auto-exposure metadata.
///
/// Designed to piggyback on existing capture sessions — reads `AVCaptureDevice.iso`
/// and `.exposureDuration` rather than running a separate capture pipeline.
/// Internally throttled to sample once every ~2 seconds.
nonisolated final class AmbientLightDetector {

  private let _onLuxChange = OSAllocatedUnfairLock<((Float) -> Void)?>(initialState: nil)
  var onLuxChange: ((Float) -> Void)? {
    get { _onLuxChange.withLock { $0 } }
    set { _onLuxChange.withLock { $0 = newValue } }
  }

  private let _device = OSAllocatedUnfairLock<AVCaptureDevice?>(initialState: nil)
  var device: AVCaptureDevice? {
    get { _device.withLock { $0 } }
    set { _device.withLock { $0 = newValue } }
  }

  private struct State {
    var currentLux: Float = 0
    var lastSampleTime: UInt64 = 0
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "AmbientLight")

  /// Minimum interval between samples in continuous clock ticks (~2 seconds).
  private let sampleIntervalNanos: UInt64 = 2_000_000_000

  var currentLux: Float {
    state.withLock { $0.currentLux }
  }

  /// Called from capture delegate callbacks. Internally throttles to avoid
  /// excessive computation — only reads device exposure properties once per ~2s.
  func sample() {
    let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let shouldSample = state.withLock { s in
      if now - s.lastSampleTime < sampleIntervalNanos { return false }
      s.lastSampleTime = now
      return true
    }
    guard shouldSample, let device = device else { return }

    let iso = device.iso
    let duration = Float(CMTimeGetSeconds(device.exposureDuration))
    guard iso > 0, duration > 0 else { return }

    let aperture = device.lensAperture
    // EV-based lux estimate: lux = calibration * f^2 / (ISO * t)
    let rawLux = 12.5 * aperture * aperture / (iso * duration)
    let lux = min(max(rawLux, 0.0001), 100_000)

    let shouldNotify = state.withLock { s in
      let previous = s.currentLux
      s.currentLux = lux
      if previous == 0 { return true }
      let ratio = abs(lux - previous) / previous
      return ratio > 0.1
    }

    if shouldNotify {
      logger.debug("Ambient light: \(lux, format: .fixed(precision: 1)) lux")
      onLuxChange?(lux)
    }
  }

  func reset() {
    _device.withLock { $0 = nil }
    state.withLock { s in
      s.currentLux = 0
      s.lastSampleTime = 0
    }
  }
}
