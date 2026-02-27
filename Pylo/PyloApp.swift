import CoreImage.CIFilterBuiltins
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
  @State private var viewModel = HAPViewModel()

  init() {
    #if os(iOS)
      // Intentionally never balanced with endGeneratingDeviceOrientationNotifications()
      // because the App struct lives for the entire process lifetime and orientation
      // data is needed continuously for camera stream rotation.
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ContentView(viewModel: viewModel)
        .task {
          viewModel.restorePreferences()
        }
    }
  }
}

// MARK: - Accessory Config Snapshot

/// Captures the accessory-enable state at server start so we can detect
/// whether settings have actually diverged (not just toggled and toggled back).
struct AccessoryConfig: Equatable {
  var flashlightEnabled: Bool
  var cameraEnabled: Bool
  var lightSensorEnabled: Bool
  var motionEnabled: Bool

  init(
    flashlightEnabled: Bool, cameraEnabled: Bool,
    lightSensorEnabled: Bool, motionEnabled: Bool
  ) {
    self.flashlightEnabled = flashlightEnabled
    self.cameraEnabled = cameraEnabled
    self.lightSensorEnabled = lightSensorEnabled
    self.motionEnabled = motionEnabled
  }

  init(from vm: HAPViewModel) {
    flashlightEnabled = vm.flashlightEnabled
    cameraEnabled = vm.selectedStreamCamera != nil
    lightSensorEnabled = vm.selectedCamera != nil
    motionEnabled = vm.motionEnabled
  }
}

// MARK: - View Model

@Observable
final class HAPViewModel {

  var isRunning = false
  var isStarting = false
  var isLightOn = false
  var brightness: Int = 100
  var isPaired = false
  var statusMessage = "Tap Start to begin"
  var setupCode = PairSetupHandler.setupCode
  var ambientLux: Float = 1.0
  var isMotionDetected = false
  var isMotionAvailable = false
  var isCameraStreaming = false
  var hasPairings = false
  var availableCameras: [CameraOption] = []
  var selectedCamera: CameraOption? {
    didSet {
      guard !isRestoring, oldValue?.id != selectedCamera?.id else { return }
      if let selectedCamera {
        UserDefaults.standard.set(selectedCamera.id, forKey: "selectedCameraID")
        lightMonitor?.restart(with: selectedCamera)
      } else {
        UserDefaults.standard.set("none", forKey: "selectedCameraID")
        lightMonitor?.stop()
      }
    }
  }
  var selectedStreamCamera: CameraOption? {
    didSet {
      guard !isRestoring, oldValue?.id != selectedStreamCamera?.id else { return }
      if let selectedStreamCamera {
        UserDefaults.standard.set(selectedStreamCamera.id, forKey: "selectedStreamCameraID")
        cameraAccessory?.selectedCameraID = selectedStreamCamera.id
      } else {
        UserDefaults.standard.set("none", forKey: "selectedStreamCameraID")
        cameraAccessory?.selectedCameraID = nil
      }
    }
  }
  var flashlightEnabled: Bool = true {
    didSet {
      guard !isRestoring, flashlightEnabled != oldValue else { return }
      UserDefaults.standard.set(flashlightEnabled, forKey: "flashlightEnabled")
    }
  }
  var motionEnabled: Bool = true {
    didSet {
      guard !isRestoring, motionEnabled != oldValue else { return }
      UserDefaults.standard.set(motionEnabled, forKey: "motionEnabled")
      if motionEnabled {
        motionMonitor?.start()
      } else {
        motionMonitor?.stop()
        isMotionDetected = false
      }
    }
  }
  var motionSensitivity: MotionSensitivity = .medium {
    didSet {
      guard !isRestoring, motionSensitivity != oldValue else { return }
      UserDefaults.standard.set(motionSensitivity.rawValue, forKey: "motionSensitivity")
      motionMonitor?.threshold = motionSensitivity.threshold
    }
  }
  var videoQuality: VideoQuality = .medium {
    didSet {
      guard !isRestoring, videoQuality != oldValue else { return }
      UserDefaults.standard.set(videoQuality.rawValue, forKey: "videoQuality")
      cameraAccessory?.minimumBitrate = videoQuality.minimumBitrate
    }
  }
  // NOTE: iOS does not offer a background mode suitable for a HAP server.
  // The app cannot run indefinitely in the background, so keeping the screen
  // awake (opt-in) is the best available workaround to stay reachable.
  var keepScreenAwake: Bool = false {
    didSet {
      guard !isRestoring, keepScreenAwake != oldValue else { return }
      UserDefaults.standard.set(keepScreenAwake, forKey: "keepScreenAwake")
      UIApplication.shared.isIdleTimerDisabled = keepScreenAwake && isRunning
    }
  }
  var screenSaverEnabled: Bool = false {
    didSet {
      guard !isRestoring, screenSaverEnabled != oldValue else { return }
      UserDefaults.standard.set(screenSaverEnabled, forKey: "screenSaverEnabled")
    }
  }
  var screenSaverDelay: TimeInterval = 60 {
    didSet {
      guard !isRestoring, screenSaverDelay != oldValue else { return }
      UserDefaults.standard.set(screenSaverDelay, forKey: "screenSaverDelay")
    }
  }

  /// Configuration snapshot taken when the server starts. Compared against
  /// current values to determine whether a restart is needed.
  @ObservationIgnored var startedConfig: AccessoryConfig?

  /// Whether the accessory configuration has diverged from what the server launched with.
  var needsRestart: Bool {
    guard let startedConfig else { return false }
    return startedConfig != AccessoryConfig(from: self)
  }

  /// Suppresses didSet side effects (UserDefaults writes, monitor restarts)
  /// while restoring persisted preferences during start().
  @ObservationIgnored var isRestoring = false

  @ObservationIgnored private var server: HAPServer?
  @ObservationIgnored private var lightMonitor: AmbientLightMonitor?
  @ObservationIgnored private var motionMonitor: MotionMonitor?
  @ObservationIgnored private var batteryMonitor: BatteryMonitor?
  @ObservationIgnored private var cameraAccessory: HAPCameraAccessory?

  /// Restores persisted preferences so the configure screen shows saved state.
  /// Called once when the app launches, before the user presses Start.
  @MainActor
  func restorePreferences() {
    isRestoring = true
    if UserDefaults.standard.object(forKey: "flashlightEnabled") != nil {
      flashlightEnabled = UserDefaults.standard.bool(forKey: "flashlightEnabled")
    }
    if UserDefaults.standard.object(forKey: "motionEnabled") != nil {
      motionEnabled = UserDefaults.standard.bool(forKey: "motionEnabled")
    }
    if let savedSensitivity = UserDefaults.standard.string(forKey: "motionSensitivity"),
      let sensitivity = MotionSensitivity(rawValue: savedSensitivity)
    {
      motionSensitivity = sensitivity
    }
    if let savedQuality = UserDefaults.standard.string(forKey: "videoQuality"),
      let quality = VideoQuality(rawValue: savedQuality)
    {
      videoQuality = quality
    }
    keepScreenAwake = UserDefaults.standard.bool(forKey: "keepScreenAwake")
    screenSaverEnabled = UserDefaults.standard.bool(forKey: "screenSaverEnabled")
    let savedDelay = UserDefaults.standard.double(forKey: "screenSaverDelay")
    if savedDelay > 0 { screenSaverDelay = savedDelay }

    // Discover available cameras and restore selections
    let cameras = CameraOption.availableCameras()
    availableCameras = cameras
    let savedCameraID = UserDefaults.standard.string(forKey: "selectedCameraID")
    if savedCameraID == "none" {
      selectedCamera = nil
    } else {
      selectedCamera =
        cameras.first(where: { $0.id == savedCameraID })
        ?? cameras.first { $0.name.localizedCaseInsensitiveContains("front") }
        ?? cameras.first
    }
    let savedStreamID = UserDefaults.standard.string(forKey: "selectedStreamCameraID")
    if savedStreamID == "none" {
      selectedStreamCamera = nil
    } else {
      selectedStreamCamera =
        cameras.first(where: { $0.id == savedStreamID })
        ?? cameras.first { $0.name.localizedCaseInsensitiveContains("back") }
        ?? cameras.first
    }
    hasPairings = PairingStore().isPaired
    isRestoring = false

    if UserDefaults.standard.bool(forKey: "hasStartedBefore") {
      start()
    }
  }

  @MainActor
  func start() {
    guard !isRunning && !isStarting else { return }
    isStarting = true
    startedConfig = AccessoryConfig(from: self)
    statusMessage = "Starting…"

    // Defer heavy work so the UI can render the starting state first.
    Task { @MainActor in
      await Task.yield()

      let serial = UIDevice.current.identifierForVendor?.uuidString ?? "000000"

      let bridge = HAPBridgeInfo(
        name: "Pylo Bridge",
        model: "HAP-PoC",
        manufacturer: "DIY",
        serialNumber: serial,
        firmwareRevision: "0.1.0"
      )

      let lightbulb = HAPAccessory(
        aid: 2,
        name: "Pylo Flashlight",
        model: "HAP-PoC",
        manufacturer: "DIY",
        serialNumber: serial + "-light",
        firmwareRevision: "0.1.0"
      )

      let camera = HAPCameraAccessory(
        aid: 3,
        name: "Pylo Camera",
        model: "HAP-PoC",
        manufacturer: "DIY",
        serialNumber: serial + "-cam",
        firmwareRevision: "0.1.0"
      )

      let lightSensor = HAPLightSensorAccessory(
        aid: 4,
        name: "Pylo Light Sensor",
        model: "HAP-PoC",
        manufacturer: "DIY",
        serialNumber: serial + "-lux",
        firmwareRevision: "0.1.0"
      )

      let motionSensor = HAPMotionSensorAccessory(
        aid: 5,
        name: "Pylo Motion Sensor",
        model: "HAP-PoC",
        manufacturer: "DIY",
        serialNumber: serial + "-motion",
        firmwareRevision: "0.1.0"
      )

      let pairingStore = PairingStore()
      let identity = DeviceIdentity()

      // Wire up state change callbacks and build accessories list
      var enabledAccessories: [HAPAccessoryProtocol] = []

      if self.flashlightEnabled {
        lightbulb.onStateChange = { [weak self] aid, iid, value in
          Task { @MainActor in
            guard let self else { return }
            if iid == HAPAccessory.iidOn, case .bool(let on) = value {
              self.isLightOn = on
            } else if iid == HAPAccessory.iidBrightness, case .int(let b) = value {
              self.brightness = b
            }
            self.server?.notifySubscribers(aid: aid, iid: iid, value: value)
          }
        }
        enabledAccessories.append(lightbulb)
      }

      if self.selectedStreamCamera != nil {
        camera.onStateChange = { [weak self] aid, iid, value in
          Task { @MainActor in
            guard let self else { return }
            if iid == HAPCameraAccessory.iidStreamingStatus,
              case .string(let b64) = value,
              let data = Data(base64Encoded: b64), data.count >= 3
            {
              self.isCameraStreaming = data[data.startIndex + 2] == 1
            }
            self.server?.notifySubscribers(aid: aid, iid: iid, value: value)
          }
        }
        self.cameraAccessory = camera
        camera.selectedCameraID = self.selectedStreamCamera?.id
        camera.minimumBitrate = self.videoQuality.minimumBitrate
        enabledAccessories.append(camera)
      }

      if self.selectedCamera != nil {
        lightSensor.onStateChange = { [weak self] aid, iid, value in
          Task { @MainActor in
            guard let self else { return }
            if iid == HAPLightSensorAccessory.iidAmbientLightLevel,
              case .float(let lux) = value
            {
              self.ambientLux = lux
            }
            self.server?.notifySubscribers(aid: aid, iid: iid, value: value)
          }
        }
        enabledAccessories.append(lightSensor)
      }

      // Set up ambient light monitor
      let monitor = AmbientLightMonitor()
      monitor.onLuxUpdate = { [weak lightSensor] lux in
        lightSensor?.updateAmbientLight(lux)
      }
      self.lightMonitor = monitor

      // Pause/resume the light monitor around snapshot captures so only
      // one AVCaptureSession is active at a time (iOS limitation).
      camera.onSnapshotWillCapture = { [weak monitor] in
        monitor?.pauseSession()
      }
      camera.onSnapshotDidCapture = { [weak monitor] in
        monitor?.resumeSession()
      }

      if self.motionEnabled {
        motionSensor.onStateChange = { [weak self] aid, iid, value in
          Task { @MainActor in
            guard let self else { return }
            if iid == HAPMotionSensorAccessory.iidMotionDetected,
              case .bool(let detected) = value
            {
              self.isMotionDetected = detected
            }
            self.server?.notifySubscribers(aid: aid, iid: iid, value: value)
          }
        }
        enabledAccessories.append(motionSensor)
      }

      // Set up motion monitor (accelerometer)
      let motion = MotionMonitor()
      motion.threshold = self.motionSensitivity.threshold
      self.isMotionAvailable = motion.isAvailable
      motion.onMotionChange = { [weak motionSensor] detected in
        motionSensor?.updateMotionDetected(detected)
      }
      self.motionMonitor = motion

      // Set up battery monitor — share a single BatteryState across all accessories
      let battery = BatteryMonitor()
      battery.start()
      if battery.isAvailable {
        let sharedBatteryState = battery.currentState()
        lightbulb.batteryState = sharedBatteryState
        camera.batteryState = sharedBatteryState
        lightSensor.batteryState = sharedBatteryState
        motionSensor.batteryState = sharedBatteryState

        battery.onBatteryChange = { [weak self] state in
          Task { @MainActor in
            guard let self, let server = self.server else { return }
            // Update shared state in-place
            sharedBatteryState.level = state.level
            sharedBatteryState.chargingState = state.chargingState
            sharedBatteryState.statusLowBattery = state.statusLowBattery
            // Notify subscribers for each enabled accessory
            for accessory in enabledAccessories {
              server.notifySubscribers(
                aid: accessory.aid, iid: BatteryIID.batteryLevel,
                value: .int(state.level))
              server.notifySubscribers(
                aid: accessory.aid, iid: BatteryIID.chargingState,
                value: .int(state.chargingState))
              server.notifySubscribers(
                aid: accessory.aid, iid: BatteryIID.statusLowBattery,
                value: .int(state.statusLowBattery))
            }
          }
        }
      }
      self.batteryMonitor = battery

      pairingStore.onChange = { [weak self] in
        Task { @MainActor in
          withAnimation { self?.hasPairings = pairingStore.isPaired }
        }
      }

      do {
        let hapServer = try HAPServer(
          bridge: bridge,
          accessories: enabledAccessories,
          pairingStore: pairingStore,
          deviceIdentity: identity
        )
        hapServer.start()
        self.server = hapServer
        self.hasPairings = pairingStore.isPaired
        withAnimation { self.isRunning = true }
        self.isStarting = false
        self.statusMessage = "Advertising as '\(bridge.name)'\nDevice ID: \(identity.deviceID)"
        UserDefaults.standard.set(true, forKey: "hasStartedBefore")

        // Start ambient light monitoring with selected camera (if any)
        if self.selectedCamera != nil {
          monitor.start(with: self.selectedCamera)
        }

        // Start motion monitoring if enabled
        if self.motionEnabled {
          motion.start()
        }

        UIApplication.shared.isIdleTimerDisabled = self.keepScreenAwake
      } catch {
        self.isRestoring = false
        self.isStarting = false
        self.statusMessage = "Failed to start: \(error.localizedDescription)"
      }
    }
  }

  @MainActor
  func stop() {
    batteryMonitor?.stop()
    batteryMonitor = nil
    motionMonitor?.stop()
    motionMonitor = nil
    lightMonitor?.stop()
    lightMonitor = nil
    cameraAccessory = nil
    server?.stop()
    server = nil
    withAnimation { isRunning = false }
    startedConfig = nil
    UIApplication.shared.isIdleTimerDisabled = false
    statusMessage = "Stopped"
  }

  @MainActor
  func restart() {
    stop()
    start()
  }

  @MainActor
  func resetPairings() {
    if let server {
      server.pairingStore.removeAll()
      server.updateAdvertisement()
    } else {
      PairingStore().removeAll()
    }
    withAnimation { hasPairings = false }
  }
}

// MARK: - HomeKit QR Code Helpers

/// Build the `X-HM://` setup URI defined by the HAP spec (§8.6.1).
/// The payload is a 45-bit integer, base-36 encoded and zero-padded to 9 chars:
///   bits  0–26: setup code as plain integer (digits without dashes)
///   bits 27–30: accessory category (4 bits)
///   bits 31–34: status flags (4 bits, 2 = IP)
///   bits 35–44: reserved / version (0)
func hapSetupURI(setupCode: String, category: Int = HAPAccessoryCategory.bridge.rawValue)
  -> String
{
  let digits = setupCode.filter(\.isWholeNumber)
  guard let code = UInt64(digits) else { return "" }
  let flags: UInt64 = 2  // IP accessory
  var payload: UInt64 = 0
  payload |= code
  payload |= UInt64(category) << 27
  payload |= flags << 31

  // Base-36 encode, uppercase, zero-padded to 9 characters
  var encoded = String(payload, radix: 36, uppercase: true)
  while encoded.count < 9 { encoded = "0" + encoded }
  return "X-HM://\(encoded)\(PairSetupHandler.setupID)"
}

/// Generate a crisp QR code `UIImage` from a string using CoreImage.
func generateQRCode(from string: String) -> UIImage? {
  let context = CIContext()
  let filter = CIFilter.qrCodeGenerator()
  filter.message = Data(string.utf8)
  filter.correctionLevel = "M"
  guard let output = filter.outputImage else { return nil }
  let scale = CGAffineTransform(scaleX: 10, y: 10)
  let scaled = output.transformed(by: scale)
  guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
  return UIImage(cgImage: cgImage)
}
