import HAP
import Streaming
import SwiftUI

// MARK: - Video Quality

nonisolated enum MaxResolution: String, CaseIterable, Identifiable, Sendable {
  case r1080p = "1080p"
  case r720p = "720p"
  case r480p = "480p"

  var id: String { rawValue }

  var width: Int {
    switch self {
    case .r1080p: return 1920
    case .r720p: return 1280
    case .r480p: return 854
    }
  }

  var height: Int {
    switch self {
    case .r1080p: return 1080
    case .r720p: return 720
    case .r480p: return 480
    }
  }

  /// All resolutions at or below this setting, for advertising to HomeKit.
  var advertisedResolutions: [MaxResolution] {
    let all = MaxResolution.allCases  // [1080p, 720p, 480p]
    guard let idx = all.firstIndex(of: self) else { return [self] }
    return Array(all[idx...])
  }
}

nonisolated enum FrameRate: Int, CaseIterable, Identifiable, Sendable {
  case fps30 = 30
  case fps24 = 24
  case fps15 = 15

  var id: Int { rawValue }

  var label: String { "\(rawValue) fps" }
}

// MARK: - Motion Sensitivity

enum MotionSensitivity: String, CaseIterable, Identifiable {
  case low = "Low"
  case medium = "Medium"
  case high = "High"

  var id: String { rawValue }

  /// Acceleration delta from gravity (in g) required to trigger motion detected.
  var threshold: Double {
    switch self {
    case .low: return 0.30
    case .medium: return 0.15
    case .high: return 0.05
    }
  }
}

// MARK: - Occupancy Cooldown

enum OccupancyCooldown: String, CaseIterable, Identifiable {
  case oneMinute = "1 min"
  case twoMinutes = "2 min"
  case fiveMinutes = "5 min"
  case tenMinutes = "10 min"

  var id: String { rawValue }

  /// Cooldown duration in seconds.
  var duration: TimeInterval {
    switch self {
    case .oneMinute: return 60
    case .twoMinutes: return 120
    case .fiveMinutes: return 300
    case .tenMinutes: return 600
    }
  }
}

// MARK: - App Entry Point
// This is the main SwiftUI app. Create a new Xcode project (iOS App, SwiftUI)
// and replace the generated ContentView / App with this.

@main
struct PyloApp: App {
  // Ensure keyStore is set before HAPViewModel initializes (which accesses PairSetupHandler.setupCode).
  private static let _ensureKeyStore: Void = {
    PairSetupHandler.keyStore = KeychainKeyStore()
  }()

  @StateObject private var viewModel = {
    _ensureKeyStore
    return HAPViewModel()
  }()

  init() {
    #if os(iOS)
      // Intentionally never balanced with endGeneratingDeviceOrientationNotifications()
      // because the App struct lives for the entire process lifetime and orientation
      // data is needed continuously for camera stream rotation.
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      // Seed the orientation cache on MainActor so it reads
      // UIDevice.current.orientation safely before any background access.
      DeviceOrientationCache.seed()
    #endif
    verifyHomeKitUUIDs()
  }

  var body: some Scene {
    WindowGroup {
      ContentView(viewModel: viewModel)
    }
  }
}
