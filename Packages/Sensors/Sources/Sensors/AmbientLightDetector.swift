import AVFoundation
import Locked
import os

/// Estimates ambient light level (lux) from camera auto-exposure metadata.
///
/// Designed to piggyback on existing capture sessions — reads `AVCaptureDevice.iso`
/// and `.exposureDuration` rather than running a separate capture pipeline.
/// Caller is responsible for throttling (e.g., calling every Nth frame).
public nonisolated final class AmbientLightDetector {

  private let _onLuxChange = Locked<((Float) -> Void)?>(initialState: nil)
  public var onLuxChange: ((Float) -> Void)? {
    get { _onLuxChange.withLock { $0 } }
    set { _onLuxChange.withLock { $0 = newValue } }
  }

  private let _device = Locked<AVCaptureDevice?>(initialState: nil)
  public var device: AVCaptureDevice? {
    get { _device.withLock { $0 } }
    set { _device.withLock { $0 = newValue } }
  }

  private struct State {
    var currentLux: Float = 0
  }
  private let state = Locked(initialState: State())

  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AmbientLight")

  public var currentLux: Float {
    state.withLock { $0.currentLux }
  }

  public init() {}

  /// Called from capture delegate callbacks.
  /// Caller is responsible for throttling (e.g., calling every Nth frame).
  public func sample() {
    guard let device = device else { return }

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

  public func reset() {
    _device.withLock { $0 = nil }
    state.withLock { s in
      s.currentLux = 0
    }
  }
}
