import AVFoundation
import Locked
import os

/// Estimates ambient light level (lux) from camera auto-exposure metadata.
///
/// Designed to piggyback on existing capture sessions — reads `AVCaptureDevice.iso`
/// and `.exposureDuration` rather than running a separate capture pipeline.
/// Caller is responsible for throttling (e.g., calling every Nth frame).
public nonisolated final class AmbientLightDetector {

  /// Whether ambient light sensing is available on this platform.
  /// macOS webcams lack meaningful exposure metadata for lux estimation.
  #if os(iOS)
    public static let isAvailable = true
  #else
    public static let isAvailable = false
  #endif

  private let _onLuxChange = Locked<((Float) -> Void)?>(initialState: nil)
  public var onLuxChange: ((Float) -> Void)? {
    get { _onLuxChange.withLockUnchecked { $0 } }
    set { _onLuxChange.withLockUnchecked { $0 = newValue } }
  }

  private let _device = Locked<AVCaptureDevice?>(initialState: nil)
  public var device: AVCaptureDevice? {
    get { _device.withLockUnchecked { $0 } }
    set { _device.withLockUnchecked { $0 = newValue } }
  }

  private struct State {
    var currentLux: Float = 0
  }
  private let state = Locked(initialState: State())

  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sensors", category: "AmbientLight")

  public var currentLux: Float {
    state.withLock { $0.currentLux }
  }

  public init() {}

  /// EV-based lux estimate: lux = calibration * f² / (ISO * t), clamped to [0.0001, 100_000].
  static func estimateLux(iso: Float, exposureDuration: Float, aperture: Float) -> Float {
    let rawLux = 12.5 * aperture * aperture / (iso * exposureDuration)
    return min(max(rawLux, 0.0001), 100_000)
  }

  /// Returns true if the new lux value differs from previous by more than 10%,
  /// or if previous is zero (first reading).
  static func shouldNotify(previous: Float, current: Float) -> Bool {
    if previous == 0 { return true }
    let ratio = abs(current - previous) / previous
    return ratio > 0.1
  }

  /// Called from capture delegate callbacks.
  /// Caller is responsible for throttling (e.g., calling every Nth frame).
  public func sample() {
    #if os(iOS)
      guard let device = device else { return }

      let iso = device.iso
      let duration = Float(CMTimeGetSeconds(device.exposureDuration))
      guard iso > 0, duration > 0 else { return }

      let lux = Self.estimateLux(
        iso: iso, exposureDuration: duration, aperture: device.lensAperture)

      let notify = state.withLock { s in
        let previous = s.currentLux
        s.currentLux = lux
        return Self.shouldNotify(previous: previous, current: lux)
      }

      // Note: a concurrent reset() between the lock above and the callback
      // below could nil the device and zero currentLux. The callback would
      // still fire with the (now-stale) lux value. This is benign — reset()
      // is only called during teardown, and an extra notification is harmless.
      if notify {
        logger.debug("Ambient light: \(lux, format: .fixed(precision: 1)) lux")
        onLuxChange?(lux)
      }
    #endif
  }

  public func reset() {
    _device.withLockUnchecked { $0 = nil }
    state.withLock { s in
      s.currentLux = 0
    }
  }
}
