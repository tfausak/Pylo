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

  /// Reused across calls since the detection queue is serial.
  private let request = VNDetectHumanRectanglesRequest()

  /// Guards against overlapping detection requests (previous still running when next frame arrives).
  private let _processing = Locked(initialState: false)

  /// Timer that fires after the cooldown expires to clear occupancy even when
  /// no camera frames are being delivered (e.g. app backgrounded, snapshot capture).
  private let _cooldownTimer = Locked<DispatchSourceTimer?>(initialState: nil)

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

      let personDetected: Bool = autoreleasepool {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        do {
          try handler.perform([self.request])
        } catch {
          self.logger.error("[occupancy] failed: \(error)")
          return false
        }

        let results = self.request.results ?? []
        let bestConfidence = results.map(\.confidence).max() ?? 0

        if !results.isEmpty {
          self.logger.debug(
            "[occupancy] found \(results.count) results, best confidence is \(bestConfidence, format: .fixed(precision: 3))"
          )
        }

        return bestConfidence >= 0.5
      }

      if personDetected {
        let (shouldNotify, cooldown) = state.withLock { s in
          s.lastDetectionDate = Date()
          if !s.isOccupied {
            s.isOccupied = true
            return (true, s.cooldown)
          }
          return (false, s.cooldown)
        }
        logger.debug(
          "[occupancy] Check: person=yes, cooldown=\(cooldown, format: .fixed(precision: 0))s")
        if shouldNotify {
          logger.debug(
            "[occupancy] occupied, clearing in \(cooldown, format: .fixed(precision: 1)) seconds")
          onOccupancyChange?(true)
        }
        // Schedule/reschedule the cooldown timer so occupancy clears even if
        // camera frames stop (backgrounding, snapshot capture, handoff).
        scheduleCooldownTimer(delay: cooldown)
      } else {
        let (elapsed, remaining, shouldClear): (TimeInterval?, TimeInterval?, Bool) = state.withLock
        { s in
          guard s.isOccupied else { return (nil, nil, false) }
          let elapsed = Date().timeIntervalSince(s.lastDetectionDate)
          if elapsed >= s.cooldown {
            s.isOccupied = false
            return (elapsed, 0, true)
          }
          return (elapsed, s.cooldown - elapsed, false)
        }
        if let remaining {
          logger.debug(
            "[occupancy] not occupied, clearing in \(remaining, format: .fixed(precision: 1)) seconds"
          )
        } else {
          logger.debug("[occupancy] not occupied")
        }
        if shouldClear, let elapsed {
          cancelCooldownTimer()
          logger.debug("[occupancy] cleared after \(elapsed, format: .fixed(precision: 1)) seconds")
          onOccupancyChange?(false)
        }
      }
    }
  }

  /// Schedule a one-shot timer on the detection queue to clear occupancy after
  /// the cooldown, even if no more camera frames arrive.
  private func scheduleCooldownTimer(delay: TimeInterval) {
    cancelCooldownTimer()
    let timer = DispatchSource.makeTimerSource(queue: detectionQueue)
    timer.schedule(deadline: .now() + delay)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      var remainingDelay: TimeInterval?
      let shouldClear = self.state.withLock { s -> Bool in
        guard s.isOccupied else { return false }
        let elapsed = Date().timeIntervalSince(s.lastDetectionDate)
        if elapsed >= s.cooldown {
          s.isOccupied = false
          return true
        }
        // Cooldown increased or not yet elapsed; reschedule for remaining time.
        remainingDelay = s.cooldown - elapsed
        return false
      }
      if shouldClear {
        self.logger.debug("[occupancy] cooldown timer fired, clearing occupancy")
        self.onOccupancyChange?(false)
        self._cooldownTimer.withLock { $0 = nil }
      } else if let delay = remainingDelay {
        self.logger.debug("[occupancy] cooldown not yet elapsed, rescheduling in \(delay, privacy: .public)s")
        self.scheduleCooldownTimer(delay: delay)
      } else {
        self._cooldownTimer.withLock { $0 = nil }
      }
    }
    // Resume before storing so the timer is never in a suspended+visible state
    // where another thread could cancel it while suspended (which would crash).
    timer.resume()
    _cooldownTimer.withLock { $0 = timer }
  }

  private func cancelCooldownTimer() {
    _cooldownTimer.withLock { timer in
      timer?.cancel()
      timer = nil
    }
  }

  /// Reset state (call when stopping detection).
  /// Dispatches onto detectionQueue so timer cancel/resume can't race.
  func reset() {
    detectionQueue.async { [self] in
      cancelCooldownTimer()
      state.withLock { s in
        s.isOccupied = false
        s.lastDetectionDate = .distantPast
      }
    }
  }
}
