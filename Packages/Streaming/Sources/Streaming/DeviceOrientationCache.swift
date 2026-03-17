import Locked

#if os(iOS)
  import UIKit
#endif

// MARK: - Shared Device Orientation Cache

/// Thread-safe device orientation cache. Observes orientation-change notifications
/// on MainActor and caches the value atomically for any-thread reads.
/// Shared by HAPCameraAccessory and MonitoringCaptureSession to avoid duplicate observers.
#if os(iOS)
  public nonisolated enum DeviceOrientationCache {
    private static let state = Locked(
      initialState: Int(UIDeviceOrientation.portrait.rawValue)
    )

    nonisolated(unsafe) private static let token: NSObjectProtocol = {
      return NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification,
        object: nil,
        queue: .main
      ) { _ in
        let orientation = MainActor.assumeIsolated { UIDevice.current.orientation }
        // Ignore flat and unknown orientations so the cache retains the last
        // meaningful value. iPads in stands commonly report .faceUp which would
        // otherwise be treated as portrait, causing upside-down streams (#40).
        guard orientation != .faceUp, orientation != .faceDown,
          orientation != .unknown
        else { return }
        state.withLock { $0 = orientation.rawValue }
      }
    }()

    /// Seed the cache with the current orientation. Must be called from
    /// MainActor (e.g. in App.init) before any background access to `current`.
    /// This is separated from the lazy `token` initializer so that the token
    /// itself is safe to initialize from any thread.
    @MainActor
    public static func seed() {
      _ = token
      let initial = UIDevice.current.orientation
      if initial != .unknown, initial != .faceUp, initial != .faceDown {
        state.withLock { $0 = initial.rawValue }
      }
    }

    /// Current device orientation, safe to read from any thread.
    /// Lazily registers a notification observer on first access.
    public static var current: UIDeviceOrientation {
      _ = token
      return UIDeviceOrientation(rawValue: state.value) ?? .portrait
    }
  }
#endif
