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

    /// Tracks whether a real (non-flat/unknown) device orientation has ever
    /// been received. When false, indeterminate orientation notifications
    /// trigger an interface-orientation fallback to correct the default.
    private static let hasRealOrientation = Locked(initialState: false)

    nonisolated(unsafe) private static let token: NSObjectProtocol = {
      return NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { @MainActor in
          let orientation = UIDevice.current.orientation
          // Ignore flat and unknown orientations so the cache retains the last
          // meaningful value. iPads in stands commonly report .faceUp which would
          // otherwise be treated as portrait, causing upside-down streams (#40).
          if orientation == .faceUp || orientation == .faceDown
            || orientation == .unknown
          {
            // For stationary/mounted devices that never produce a real orientation,
            // fall back to the window scene's interface orientation so the cache
            // doesn't stay stuck at the default portrait.
            if !hasRealOrientation.value {
              if let mapped = interfaceOrientationFallback() {
                state.withLock { $0 = mapped.rawValue }
              }
            }
            return
          }
          hasRealOrientation.value = true
          state.withLock { $0 = orientation.rawValue }
        }
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
      } else if let mapped = interfaceOrientationFallback() {
        state.withLock { $0 = mapped.rawValue }
      }
    }

    /// Map the window scene's interface orientation to a device orientation.
    /// Used as a fallback when the device orientation is indeterminate (flat,
    /// face-up, or unknown) — common for stationary/mounted devices.
    @MainActor
    private static func interfaceOrientationFallback() -> UIDeviceOrientation? {
      guard
        let scene = UIApplication.shared.connectedScenes
          .compactMap({ $0 as? UIWindowScene }).first
      else { return nil }
      switch scene.interfaceOrientation {
      case .portrait: return .portrait
      case .portraitUpsideDown: return .portraitUpsideDown
      case .landscapeLeft: return .landscapeLeft
      case .landscapeRight: return .landscapeRight
      default: return nil
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
