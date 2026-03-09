import CoreVideo
import Vision
import os

/// Detects human presence using Vision framework person detection.
/// Processes pixel buffers from MonitoringCaptureSession at low frequency (~2.5s).
/// Maintains occupancy state with configurable cooldown to avoid flapping.
nonisolated final class OccupancySensor: @unchecked Sendable {

  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "OccupancySensor")

  private let _onOccupancyChange = Locked<((Bool) -> Void)?>(initialState: nil)
  var onOccupancyChange: ((Bool) -> Void)? {
    get { _onOccupancyChange.withLock { $0 } }
    set { _onOccupancyChange.withLock { $0 = newValue } }
  }

  /// Seconds to stay "occupied" after last person detection before clearing.
  var cooldown: TimeInterval {
    get { state.withLock { $0.cooldown } }
    set { state.withLock { $0.cooldown = newValue } }
  }

  private struct State {
    var isOccupied = false
    var lastDetectionDate = Date.distantPast
    var cooldown: TimeInterval = 300  // 5 minutes
  }

  private let state = Locked(initialState: State())

  /// Vision requests run on a dedicated queue to avoid blocking the capture pipeline.
  private let detectionQueue = DispatchQueue(
    label: "\(Bundle.main.bundleIdentifier!).occupancy", qos: .utility)

  /// Guards against overlapping detection requests (previous still running when next frame arrives).
  private let _processing = Locked(initialState: false)

  init() {}

  /// Process a pixel buffer for person detection.
  /// Safe to call from any queue. Dispatches Vision work to a dedicated queue.
  /// Caller is responsible for throttling (e.g., every ~75 frames at 30fps).
  func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
    guard
      _processing.withLock({ p in
        guard !p else { return false }
        p = true
        return true
      })
    else { return }

    // CVPixelBuffer is refcounted and retained by the closure.
    nonisolated(unsafe) let pixelBuffer = pixelBuffer
    detectionQueue.async { [self] in
      defer { _processing.withLock { $0 = false } }

      let request = VNDetectHumanRectanglesRequest()
      let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

      do {
        try handler.perform([request])
      } catch {
        logger.error("Vision request failed: \(error)")
        return
      }

      let personDetected = !(request.results?.isEmpty ?? true)

      if personDetected {
        let shouldNotify = state.withLock { s in
          s.lastDetectionDate = Date()
          if !s.isOccupied {
            s.isOccupied = true
            return true
          }
          return false
        }
        if shouldNotify {
          logger.debug("Occupancy detected")
          onOccupancyChange?(true)
        }
      } else {
        let elapsed: TimeInterval? = state.withLock { s in
          guard s.isOccupied else { return nil }
          let elapsed = Date().timeIntervalSince(s.lastDetectionDate)
          if elapsed >= s.cooldown {
            s.isOccupied = false
            return elapsed
          }
          return nil
        }
        if let elapsed {
          logger.debug("Occupancy cleared after \(elapsed, format: .fixed(precision: 0))s")
          onOccupancyChange?(false)
        }
      }
    }
  }

  /// Reset state (call when stopping detection).
  func reset() {
    state.withLock { s in
      s.isOccupied = false
      s.lastDetectionDate = .distantPast
    }
  }
}
