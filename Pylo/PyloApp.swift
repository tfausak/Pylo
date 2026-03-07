import HAP
import SwiftUI

// MARK: - Video Quality

enum VideoQuality: String, CaseIterable, Identifiable {
  case low = "Low"
  case medium = "Medium"
  case high = "High"

  var id: String { rawValue }

  /// Minimum bitrate floor in kbps.
  var minimumBitrate: Int {
    switch self {
    case .low: return 500
    case .medium: return 2000
    case .high: return 4000
    }
  }
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
