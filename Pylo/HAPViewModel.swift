import AVFoundation
import Combine
import CoreImage.CIFilterBuiltins
import FragmentedMP4
import HAP
import Locked
import Sensors
import Streaming
import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
  import IOKit
  import IOKit.pwr_mgt
#endif

// MARK: - Accessory Config Snapshot

/// Captures the accessory-enable state at server start so we can detect
/// whether settings have actually diverged (not just toggled and toggled back).
struct AccessoryConfig: Equatable {
  var flashlightEnabled: Bool
  var selectedCameraID: String?
  var motionEnabled: Bool
  var microphoneEnabled: Bool
  var contactEnabled: Bool
  var lightSensorEnabled: Bool
  var occupancyEnabled: Bool
  var sensorCameraID: String?
  var sirenEnabled: Bool
  var buttonEnabled: Bool

  init(
    flashlightEnabled: Bool, selectedCameraID: String?,
    motionEnabled: Bool, microphoneEnabled: Bool,
    contactEnabled: Bool, lightSensorEnabled: Bool,
    occupancyEnabled: Bool, sensorCameraID: String?,
    sirenEnabled: Bool, buttonEnabled: Bool
  ) {
    self.flashlightEnabled = flashlightEnabled
    self.selectedCameraID = selectedCameraID
    self.motionEnabled = motionEnabled
    self.microphoneEnabled = microphoneEnabled
    self.contactEnabled = contactEnabled
    self.lightSensorEnabled = lightSensorEnabled
    self.occupancyEnabled = occupancyEnabled
    self.sensorCameraID = sensorCameraID
    self.sirenEnabled = sirenEnabled
    self.buttonEnabled = buttonEnabled
  }

  @MainActor
  init(from vm: HAPViewModel) {
    flashlightEnabled = vm.flashlightEnabled
    selectedCameraID = vm.selectedStreamCamera?.id
    motionEnabled = vm.motionEnabled
    microphoneEnabled = vm.microphoneEnabled
    contactEnabled = vm.contactEnabled
    lightSensorEnabled = vm.lightSensorEnabled
    occupancyEnabled = vm.occupancyEnabled
    sensorCameraID = vm.sensorCamera?.id
    sirenEnabled = vm.sirenEnabled
    buttonEnabled = vm.buttonEnabled
  }
}

// MARK: - View Model

@MainActor
final class HAPViewModel: ObservableObject {

  /// App version + build number reported as firmware revision in HomeKit (e.g. "1.0.3").
  /// HAP spec requires "X.Y.Z" format for FirmwareRevision.
  nonisolated static let firmwareVersion: String = {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
    let build = info?["CFBundleVersion"] as? String ?? "0"
    return "\(version).\(build)"
  }()

  init(skipRestore: Bool = false) {
    if !skipRestore {
      setupCode = PairSetupHandler.setupCode
      setupID = PairSetupHandler.setupID
      restorePreferences()
    }
  }

  @Published var isRunning = false
  @Published var isStarting = false
  @Published var isLightOn = false
  @Published var brightness: Int = 100
  @Published var isPaired = false
  @Published var statusMessage = "Tap Start to begin"
  @Published var setupCode = ""
  internal var setupID = ""
  @Published var isMotionDetected = false
  @Published var isMotionAvailable = false
  @Published var hasCamera = false
  @Published var hasTorch = false
  @Published var hasAccelerometer = false
  let hasAmbientLight = AmbientLightDetector.isAvailable
  @Published var isCameraStreaming = false
  @Published var hasPairings = false
  @Published var isNetworkDenied = false
  @Published var isWaitingForHomeApp = false
  @Published var availableCameras: [CameraOption] = []
  @Published var selectedStreamCamera: CameraOption? {
    didSet {
      guard !isRestoring, oldValue?.id != selectedStreamCamera?.id else { return }
      if let selectedStreamCamera {
        UserDefaults.standard.set(selectedStreamCamera.id, forKey: "selectedStreamCameraID")
        cameraAccessory?.selectedCameraID = selectedStreamCamera.id
        // Keep sensor camera in sync so sensors use the same camera
        sensorCamera = selectedStreamCamera
      } else {
        UserDefaults.standard.set("none", forKey: "selectedStreamCameraID")
        cameraAccessory?.selectedCameraID = nil
      }
    }
  }
  /// Which camera device sensors use when the camera accessory is off.
  /// Synced from selectedStreamCamera; persisted independently.
  @Published var sensorCamera: CameraOption? {
    didSet {
      guard !isRestoring, oldValue?.id != sensorCamera?.id else { return }
      if let sensorCamera {
        UserDefaults.standard.set(sensorCamera.id, forKey: "sensorCameraID")
      } else {
        UserDefaults.standard.removeObject(forKey: "sensorCameraID")
      }
    }
  }
  @Published var flashlightEnabled: Bool = false {
    didSet {
      guard !isRestoring, flashlightEnabled != oldValue else { return }
      UserDefaults.standard.set(flashlightEnabled, forKey: "flashlightEnabled")
    }
  }
  @Published var motionEnabled: Bool = false {
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
  @Published var motionSensitivity: MotionSensitivity = .medium {
    didSet {
      guard !isRestoring, motionSensitivity != oldValue else { return }
      UserDefaults.standard.set(motionSensitivity.rawValue, forKey: "motionSensitivity")
      motionMonitor?.threshold = motionSensitivity.threshold
    }
  }
  @Published var contactEnabled: Bool = false {
    didSet {
      guard !isRestoring, contactEnabled != oldValue else { return }
      UserDefaults.standard.set(contactEnabled, forKey: "contactEnabled")
      if contactEnabled {
        proximitySensor?.start()
      } else {
        proximitySensor?.stop()
        isContactDetected = false
      }
    }
  }
  @Published var isContactDetected = false
  @Published var hasProximity = false
  @Published var microphoneEnabled: Bool = false {
    didSet {
      guard !isRestoring, microphoneEnabled != oldValue else { return }
      UserDefaults.standard.set(microphoneEnabled, forKey: "microphoneEnabled")
      cameraAccessory?.microphoneEnabled = microphoneEnabled
    }
  }
  @Published var lightSensorEnabled: Bool = false {
    didSet {
      guard !isRestoring, lightSensorEnabled != oldValue else { return }
      UserDefaults.standard.set(lightSensorEnabled, forKey: "lightSensorEnabled")
    }
  }
  @Published var occupancyEnabled: Bool = false {
    didSet {
      guard !isRestoring, occupancyEnabled != oldValue else { return }
      UserDefaults.standard.set(occupancyEnabled, forKey: "occupancyEnabled")
    }
  }
  @Published var occupancyCooldown: OccupancyCooldown = .fiveMinutes {
    didSet {
      guard !isRestoring, occupancyCooldown != oldValue else { return }
      UserDefaults.standard.set(occupancyCooldown.rawValue, forKey: "occupancyCooldown")
      occupancySensor?.cooldown = occupancyCooldown.duration
    }
  }
  @Published var isOccupancyDetected = false
  @Published var videoQuality: VideoQuality = .medium {
    didSet {
      guard !isRestoring, videoQuality != oldValue else { return }
      UserDefaults.standard.set(videoQuality.rawValue, forKey: "videoQuality")
      cameraAccessory?.minimumBitrate = videoQuality.minimumBitrate
    }
  }
  @Published var sirenEnabled: Bool = false {
    didSet {
      guard !isRestoring, sirenEnabled != oldValue else { return }
      UserDefaults.standard.set(sirenEnabled, forKey: "sirenEnabled")
    }
  }
  @Published var buttonEnabled: Bool = false {
    didSet {
      guard !isRestoring, buttonEnabled != oldValue else { return }
      UserDefaults.standard.set(buttonEnabled, forKey: "buttonEnabled")
    }
  }
  @Published var isSirenActive = false

  // NOTE: iOS does not offer a background mode suitable for a HAP server.
  // The app cannot run indefinitely in the background, so keeping the screen
  // awake (enabled by default but user-configurable) is the best available workaround to stay reachable.
  @Published var keepScreenAwake: Bool = true {
    didSet {
      guard !isRestoring, keepScreenAwake != oldValue else { return }
      UserDefaults.standard.set(keepScreenAwake, forKey: "keepScreenAwake")
      updateIdleTimer()
    }
  }
  /// Whether camera permission has been expressly denied or restricted.
  @Published var cameraPermissionDenied = false

  /// Whether microphone permission has been expressly denied or restricted.
  @Published var microphonePermissionDenied = false

  /// Which permission was denied — drives the alert in ContentView.
  @Published var permissionAlert: PermissionKind?

  enum PermissionKind {
    case camera, microphone
    var title: String {
      switch self {
      case .camera: "Camera Access Required"
      case .microphone: "Microphone Access Required"
      }
    }
    var message: String {
      switch self {
      case .camera:
        "Pylo needs camera access for the camera and flashlight. You can enable it in Settings."
      case .microphone: "Pylo needs microphone access for audio. You can enable it in Settings."
      }
    }
  }

  /// Configuration snapshot taken when the server starts. Compared against
  /// current values to determine whether a restart is needed.
  var startedConfig: AccessoryConfig?

  /// Whether the accessory configuration has diverged from what the server launched with.
  var needsRestart: Bool {
    guard let startedConfig else { return false }
    return startedConfig != AccessoryConfig(from: self)
  }

  /// Suppresses didSet side effects (UserDefaults writes, monitor restarts)
  /// while restoring persisted preferences during start().
  var isRestoring = false

  private var startTask: Task<Void, Never>?
  private var recheckTask: Task<Void, Never>?
  private var startGeneration = 0
  /// Whether the listener has been `.ready` at least once during this server
  /// session. Used to suppress the "network denied" screen when NWListener
  /// enters `.waiting` during normal background suspension (not actual denial).
  private var wasListenerReady = false
  /// Tracks the actual listener state independently of the UI-facing
  /// `isNetworkDenied`, which may be suppressed during background transitions.
  private var listenerActuallyReady = false
  private var server: HAPServer?
  private var motionMonitor: MotionMonitor?
  private var batteryMonitor: BatteryMonitor?
  private var lightbulbAccessory: HAPAccessory?
  private var cameraAccessory: HAPCameraAccessory?
  private var buttonAccessory: HAPButtonAccessory?
  private var monitoringSession: MonitoringCaptureSession?
  private var fragmentWriter: FragmentedMP4Writer?
  private var dataStreamHandler: HAPDataStream?
  private var proximitySensor: ProximitySensor?
  private var occupancySensor: OccupancySensor?
  private var sirenPlayer: SirenPlayer?

  // MARK: - Permissions

  /// Request camera permission. Returns true if granted.
  @MainActor
  func requestCameraPermission() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized: return true
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .video)
      if !granted { cameraPermissionDenied = true }
      return granted
    case .denied, .restricted:
      cameraPermissionDenied = true
      return false
    @unknown default:
      return false
    }
  }

  /// Request microphone permission. Returns true if granted.
  @MainActor
  func requestMicrophonePermission() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    switch status {
    case .authorized: return true
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .audio)
      if !granted { microphonePermissionDenied = true }
      return granted
    case .denied, .restricted:
      microphonePermissionDenied = true
      return false
    @unknown default:
      return false
    }
  }

  /// Silently check permissions and disable accessories whose permissions were revoked.
  /// Uses `isRestoring` to suppress UserDefaults writes so the user's saved preferences
  /// are not overwritten by a temporary permission denial.
  @MainActor
  func recheckPermissions() {
    let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    cameraPermissionDenied = cameraStatus == .denied || cameraStatus == .restricted
    if cameraPermissionDenied {
      isRestoring = true
      defer { isRestoring = false }
      if flashlightEnabled { flashlightEnabled = false }
      if selectedStreamCamera != nil { selectedStreamCamera = nil }
      if lightSensorEnabled { lightSensorEnabled = false }
      if occupancyEnabled { occupancyEnabled = false }
    }
    let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    microphonePermissionDenied = micStatus == .denied || micStatus == .restricted
    if microphonePermissionDenied {
      isRestoring = true
      defer { isRestoring = false }
      if microphoneEnabled { microphoneEnabled = false }
    }

    updateIdleTimer()

    // Re-check listener state. NWListener enters .waiting when the app is
    // backgrounded and may not auto-recover to .ready on foreground. The
    // onListenerStateChange callback suppresses .waiting when the listener
    // was previously ready (wasListenerReady), so the UI won't flash the
    // "denied" screen. Here we actively verify and restart if stuck.
    guard server != nil else { return }
    server?.recheckListenerState()
    recheckTask?.cancel()
    recheckTask = Task { @MainActor [weak self] in
      // Poll with increasing delays, giving the listener time to recover.
      for delay in [0.5, 1.0, 2.0, 4.0] {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard let self, !Task.isCancelled else { return }
        if self.listenerActuallyReady { return }
        self.server?.recheckListenerState()
      }
      guard let self else { return }
      // Listener is still not ready after ~7.5s. Cancel and create a fresh
      // NWListener — the old one is stuck in .waiting from suspension.
      guard !Task.isCancelled, !self.listenerActuallyReady else { return }
      self.server?.restartListener()
      // Give the new listener time to start and fire stateUpdateHandler.
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled, !self.listenerActuallyReady else { return }
      // Still not ready even after restart — genuinely denied.
      withAnimation { self.isNetworkDenied = true }
    }
  }

  /// Stop the active camera stream when the app is backgrounded.
  /// iOS invalidates hardware codec sessions (VTCompressionSession) on suspend,
  /// so the stream is effectively dead. Notify HomeKit immediately so Home.app
  /// stops showing a frozen/dead feed.
  @MainActor
  func handleBackgrounding() {
    cameraAccessory?.stopStreaming()
  }

  /// Restores persisted preferences so the configure screen shows saved state.
  /// Called once when the app launches, before the user presses Start.
  @MainActor
  func restorePreferences() {
    isRestoring = true
    defer { isRestoring = false }
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
    if UserDefaults.standard.object(forKey: "microphoneEnabled") != nil {
      microphoneEnabled = UserDefaults.standard.bool(forKey: "microphoneEnabled")
    }
    if UserDefaults.standard.object(forKey: "contactEnabled") != nil {
      contactEnabled = UserDefaults.standard.bool(forKey: "contactEnabled")
    }
    if UserDefaults.standard.object(forKey: "lightSensorEnabled") != nil {
      lightSensorEnabled = UserDefaults.standard.bool(forKey: "lightSensorEnabled")
    }
    if UserDefaults.standard.object(forKey: "occupancyEnabled") != nil {
      occupancyEnabled = UserDefaults.standard.bool(forKey: "occupancyEnabled")
    }
    if let savedCooldown = UserDefaults.standard.string(forKey: "occupancyCooldown"),
      let cooldown = OccupancyCooldown(rawValue: savedCooldown)
    {
      occupancyCooldown = cooldown
    }
    if UserDefaults.standard.object(forKey: "sirenEnabled") != nil {
      sirenEnabled = UserDefaults.standard.bool(forKey: "sirenEnabled")
    }
    if UserDefaults.standard.object(forKey: "buttonEnabled") != nil {
      buttonEnabled = UserDefaults.standard.bool(forKey: "buttonEnabled")
    }
    if UserDefaults.standard.object(forKey: "keepScreenAwake") != nil {
      keepScreenAwake = UserDefaults.standard.bool(forKey: "keepScreenAwake")
    }
    // Discover available cameras and restore stream camera selection
    let cameras = CameraOption.availableCameras()
    availableCameras = cameras
    hasCamera = !cameras.isEmpty
    #if os(iOS)
      let discoveryTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera, .builtInTelephotoCamera, .builtInUltraWideCamera,
      ]
    #elseif os(macOS)
      var discoveryTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
      if #available(macOS 14.0, *) {
        discoveryTypes.append(.continuityCamera)
        discoveryTypes.append(.external)
      }
    #endif
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: discoveryTypes,
      mediaType: .video,
      position: .unspecified
    )
    hasTorch = discovery.devices.contains { $0.hasTorch }
    let savedStreamID = UserDefaults.standard.string(forKey: "selectedStreamCameraID")
    if savedStreamID == "none" {
      selectedStreamCamera = nil
    } else if let savedStreamID {
      selectedStreamCamera = cameras.first(where: { $0.id == savedStreamID })
    } else {
      // No saved preference (fresh install or upgrade). Leave nil so the user
      // explicitly enables via the toggle (which requests camera permission).
      selectedStreamCamera = nil
    }
    // Restore sensor camera selection (used when camera accessory is off)
    if let savedSensorID = UserDefaults.standard.string(forKey: "sensorCameraID") {
      sensorCamera = cameras.first(where: { $0.id == savedSensorID })
    } else if let selectedStreamCamera {
      // Seed from camera selection on first run after upgrade
      sensorCamera = selectedStreamCamera
    }
    // If sensors are enabled but no sensor camera resolved, auto-select the first
    // available camera so sensors don't silently fail after upgrade or camera changes.
    if sensorCamera == nil && (lightSensorEnabled || occupancyEnabled),
      let fallback = cameras.first
    {
      sensorCamera = fallback
      UserDefaults.standard.set(fallback.id, forKey: "sensorCameraID")
    }
    hasPairings = UserDefaults.standard.bool(forKey: "hasPairings")

    recheckPermissions()
    start()
  }

  @MainActor
  func start() {
    guard !isRunning && !isStarting else { return }
    isStarting = true
    startedConfig = AccessoryConfig(from: self)
    statusMessage = "Starting…"

    // Stage 1: Capture config values on MainActor before leaving isolation.
    // Start the battery monitor early so we know whether to include the
    // battery service in the accessory database (affects c# hashing).
    let battery = BatteryMonitor()
    battery.start()

    let config = StartConfig(
      serial: deviceSerial(),
      deviceModel: deviceModelName(),
      flashlightEnabled: flashlightEnabled,
      selectedStreamCameraID: selectedStreamCamera?.id,
      motionEnabled: motionEnabled,
      motionThreshold: motionSensitivity.threshold,
      minimumBitrate: videoQuality.minimumBitrate,
      microphoneEnabled: microphoneEnabled,
      contactEnabled: contactEnabled,
      lightSensorEnabled: lightSensorEnabled,
      occupancyEnabled: occupancyEnabled,
      occupancyCooldown: occupancyCooldown.duration,
      sensorCameraID: sensorCamera?.id,
      sirenEnabled: sirenEnabled,
      buttonEnabled: buttonEnabled,
      hasBattery: battery.isAvailable
    )

    let myGeneration = startGeneration
    startTask = Task { @MainActor in
      // Stage 2: Create server and all accessories off MainActor.
      // PairingStore (file I/O), DeviceIdentity (Keychain), and NWListener
      // creation are the heaviest operations moved off the main thread.
      let setup: ServerSetup
      do {
        setup = try await Task.detached {
          try createServerSetup(config: config)
        }.value
      } catch {
        // Only update state if this generation is still current (a newer
        // start() hasn't been launched by restart()).
        if self.startGeneration == myGeneration {
          self.isStarting = false
          self.isWaitingForHomeApp = false
          self.statusMessage = "Failed to start: \(error.localizedDescription)"
        }
        return
      }

      guard !Task.isCancelled, self.startGeneration == myGeneration else {
        setup.server.stop()
        setup.dataStream?.stop()
        setup.monitoringSession?.stop()
        setup.fmp4Writer?.stop()
        self.isWaitingForHomeApp = false
        return
      }

      // Stage 3: Wire UI-updating callbacks, store references, and start
      // monitors — all on MainActor.
      self.server = setup.server
      self.monitoringSession = setup.monitoringSession
      self.motionMonitor = setup.motionMonitor
      self.lightbulbAccessory = config.flashlightEnabled ? setup.lightbulb : nil
      self.cameraAccessory = config.selectedStreamCameraID != nil ? setup.camera : nil
      self.buttonAccessory = config.buttonEnabled ? setup.button : nil
      self.fragmentWriter = setup.fmp4Writer
      self.dataStreamHandler = setup.dataStream
      self.isMotionAvailable = setup.isMotionAvailable
      self.hasAccelerometer = setup.isMotionAvailable
      self.occupancySensor = setup.occupancyDetector

      // Wire state-change callbacks that update published UI state.
      // IMPORTANT: These closures run on the HAP server's background queue,
      // NOT the main queue. We must avoid capturing `self` (which is @MainActor)
      // directly, as Swift 6 with default MainActor isolation would infer
      // @MainActor on the closure, causing a runtime dispatch_assert_queue
      // failure. Instead, capture `vm` (a plain `let` copy of `self`) so
      // the closure doesn't inherit @MainActor, and hop to MainActor
      // explicitly via Task for UI updates. Strong ref is safe: stop()
      // tears down the server and clears all callbacks before the view
      // model could be deallocated.
      let vm = self
      var enabledAccessories: [any HAPAccessoryProtocol] = []

      if config.flashlightEnabled {
        setup.lightbulb.onStateChange = {
          [weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
          Task { @MainActor in

            if iid == HAPAccessory.iidOn, case .bool(let on) = value {
              vm.isLightOn = on
            } else if iid == HAPAccessory.iidBrightness, case .int(let b) = value {
              vm.brightness = b
            }
          }
        }
        enabledAccessories.append(setup.lightbulb)
      }

      if config.selectedStreamCameraID != nil {
        setup.camera.onStateChange = {
          [weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
          Task { @MainActor in

            if iid == HAPCameraAccessory.iidStreamingStatus,
              case .string(let b64) = value,
              let data = Data(base64Encoded: b64), data.count >= 3
            {
              vm.isCameraStreaming = data[data.startIndex + 2] == 1
            }
          }
        }
        enabledAccessories.append(setup.camera)
      }

      if config.motionEnabled {
        setup.motionSensor.onStateChange = {
          [weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
          Task { @MainActor in

            if iid == HAPMotionSensorAccessory.iidMotionDetected,
              case .bool(let detected) = value
            {
              vm.isMotionDetected = detected
            }
          }
        }
        enabledAccessories.append(setup.motionSensor)
      }

      if config.lightSensorEnabled {
        setup.lightSensor.onStateChange = { [weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
        }
        enabledAccessories.append(setup.lightSensor)
      }

      if config.contactEnabled {
        setup.contactSensor.onStateChange = {
          [weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
          Task { @MainActor in

            if iid == HAPContactSensorAccessory.iidContactSensorState,
              case .int(let val) = value
            {
              vm.isContactDetected = val == 0
            }
          }
        }
        enabledAccessories.append(setup.contactSensor)
      }

      if config.occupancyEnabled {
        setup.occupancySensor.onStateChange = {
          [weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
          Task { @MainActor in

            if iid == HAPOccupancySensorAccessory.iidOccupancyDetected,
              case .int(let val) = value
            {
              vm.isOccupancyDetected = val != 0
            }
          }
        }
        enabledAccessories.append(setup.occupancySensor)
      }

      if config.sirenEnabled {
        setup.siren.onStateChange = {
          [weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
          Task { @MainActor in

            if iid == HAPSirenAccessory.iidOn, case .bool(let on) = value {
              vm.isSirenActive = on
            }
          }
        }
        enabledAccessories.append(setup.siren)
      }

      if config.buttonEnabled {
        setup.button.onStateChange = {
          [weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
        }
        enabledAccessories.append(setup.button)
      }

      self.sirenPlayer = setup.sirenPlayer

      setup.server.onListenerStateChange = { ready in
        Task { @MainActor in
          vm.listenerActuallyReady = ready
          if ready {
            vm.wasListenerReady = true
            withAnimation { vm.isNetworkDenied = false }
          } else if !vm.wasListenerReady {
            withAnimation { vm.isNetworkDenied = true }
          }
        }
      }

      setup.server.onAccessoriesFetched = {
        Task { @MainActor in
          withAnimation { vm.isWaitingForHomeApp = false }
        }
      }

      setup.server.pairingStore.onChange = { [weak server = setup.server] in
        let isPaired = server?.pairingStore.isPaired ?? false
        UserDefaults.standard.set(isPaired, forKey: "hasPairings")
        Task { @MainActor in
          withAnimation {
            vm.hasPairings = isPaired
            if !isPaired { vm.isWaitingForHomeApp = false }
          }
          vm.updateIdleTimer()
        }
      }

      // Battery monitor — already created and started before server setup
      // so hasBattery could be passed to createServerSetup for c# hashing.
      if battery.isAvailable {
        let sharedBatteryState = battery.currentState()
        setup.lightbulb.batteryState = sharedBatteryState
        setup.camera.batteryState = sharedBatteryState
        setup.motionSensor.batteryState = sharedBatteryState
        setup.lightSensor.batteryState = sharedBatteryState
        setup.contactSensor.batteryState = sharedBatteryState
        setup.occupancySensor.batteryState = sharedBatteryState
        setup.siren.batteryState = sharedBatteryState
        setup.button.batteryState = sharedBatteryState

        let batteryAIDs = enabledAccessories.map(\.aid)
        battery.onBatteryChange = { [weak server = setup.server] state in
          sharedBatteryState.update(
            level: state.level,
            chargingState: state.chargingState,
            statusLowBattery: state.statusLowBattery)
          guard let server else { return }
          for aid in batteryAIDs {
            server.notifySubscribers(
              aid: aid, iid: BatteryIID.batteryLevel,
              value: .int(state.level))
            server.notifySubscribers(
              aid: aid, iid: BatteryIID.chargingState,
              value: .int(state.chargingState))
            server.notifySubscribers(
              aid: aid, iid: BatteryIID.statusLowBattery,
              value: .int(state.statusLowBattery))
          }
        }
      }
      self.batteryMonitor = battery

      // Start everything
      setup.server.start()
      let paired = setup.server.pairingStore.isPaired
      UserDefaults.standard.set(paired, forKey: "hasPairings")
      self.hasPairings = paired
      withAnimation { self.isRunning = true }
      self.isStarting = false
      self.statusMessage =
        "Advertising as '\(setup.bridge.name)'\nDevice ID: \(setup.server.deviceIdentity.deviceID)"

      if config.motionEnabled {
        setup.motionMonitor.start()
      }

      // Proximity sensor — uses UIDevice which requires MainActor.
      // Check availability even if disabled so the UI can show blocked state.
      let proximity = ProximitySensor()
      proximity.start()
      self.hasProximity = proximity.isAvailable
      if config.contactEnabled && proximity.isAvailable {
        proximity.onContactChange = { [weak contactSensor = setup.contactSensor] near in
          contactSensor?.updateContactState(near: near)
        }
        self.proximitySensor = proximity
      } else {
        proximity.stop()
      }

      updateIdleTimer()
    }
  }

  #if os(macOS)
    /// IOPMAssertion ID for preventing system sleep on macOS.
    private var sleepAssertionID: IOPMAssertionID = 0
    private var hasSleepAssertion = false
  #endif

  func updateIdleTimer() {
    #if os(iOS)
      UIApplication.shared.isIdleTimerDisabled = keepScreenAwake && isRunning && hasPairings
    #elseif os(macOS)
      let shouldPreventSleep = keepScreenAwake && isRunning && hasPairings
      if shouldPreventSleep, !hasSleepAssertion {
        let result = IOPMAssertionCreateWithName(
          kIOPMAssertionTypeNoIdleSleep as CFString,
          IOPMAssertionLevel(kIOPMAssertionLevelOn),
          "Pylo HAP server active" as CFString,
          &sleepAssertionID)
        hasSleepAssertion = result == kIOReturnSuccess
      } else if !shouldPreventSleep, hasSleepAssertion {
        IOPMAssertionRelease(sleepAssertionID)
        hasSleepAssertion = false
      }
    #endif
  }

  @MainActor
  func stop() {
    startGeneration += 1
    startTask?.cancel()
    startTask = nil
    recheckTask?.cancel()
    recheckTask = nil
    isStarting = false
    batteryMonitor?.stop()
    batteryMonitor = nil
    motionMonitor?.stop()
    motionMonitor = nil
    // stopStreaming() may hand the AVCaptureSession back to monitoringSession
    // when recording is armed, so it must run before monitoringSession is torn down.
    cameraAccessory?.stopStreaming()
    cameraAccessory = nil
    fragmentWriter?.stop()
    fragmentWriter = nil
    monitoringSession?.stop()
    monitoringSession = nil
    dataStreamHandler?.stop()
    dataStreamHandler = nil
    proximitySensor?.stop()
    proximitySensor = nil
    occupancySensor = nil
    sirenPlayer?.stop()
    sirenPlayer = nil
    lightbulbAccessory?.cancelIdentify()
    lightbulbAccessory = nil
    buttonAccessory = nil
    server?.stop()
    server = nil
    wasListenerReady = false
    listenerActuallyReady = false
    withAnimation {
      isRunning = false
      isWaitingForHomeApp = false
    }
    startedConfig = nil
    #if os(iOS)
      UIApplication.shared.isIdleTimerDisabled = false
    #elseif os(macOS)
      if hasSleepAssertion {
        IOPMAssertionRelease(sleepAssertionID)
        hasSleepAssertion = false
      }
    #endif
    statusMessage = "Stopped"
  }

  /// Restores accessory settings to the given config snapshot (used by cancel in settings).
  @MainActor
  func restoreConfig(_ config: AccessoryConfig) {
    isRestoring = true
    defer { isRestoring = false }
    flashlightEnabled = config.flashlightEnabled
    selectedStreamCamera = availableCameras.first { $0.id == config.selectedCameraID }
    motionEnabled = config.motionEnabled
    microphoneEnabled = config.microphoneEnabled
    contactEnabled = config.contactEnabled
    lightSensorEnabled = config.lightSensorEnabled
    occupancyEnabled = config.occupancyEnabled
    sensorCamera = availableCameras.first { $0.id == config.sensorCameraID }
    sirenEnabled = config.sirenEnabled
    buttonEnabled = config.buttonEnabled
  }

  @MainActor
  func restart() {
    let wasPaired = hasPairings
    stop()
    start()
    if wasPaired {
      isWaitingForHomeApp = true
    }
  }

  @MainActor
  func resetPairings() {
    if let server {
      server.pairingStore.removeAll()
      server.updateAdvertisement()
    } else {
      PairingStore().removeAll()
    }
    UserDefaults.standard.set(false, forKey: "hasPairings")
    withAnimation { hasPairings = false }
  }

  func pressButton() {
    buttonAccessory?.trigger()
  }
}

// MARK: - Server Setup (off MainActor)

/// Configuration captured from @MainActor properties for off-main-thread server creation.
private struct StartConfig: Sendable {
  let serial: String
  let deviceModel: String  // "iPhone", "iPad", etc.
  let flashlightEnabled: Bool
  let selectedStreamCameraID: String?
  let motionEnabled: Bool
  let motionThreshold: Double
  let minimumBitrate: Int
  let microphoneEnabled: Bool
  let contactEnabled: Bool
  let lightSensorEnabled: Bool
  let occupancyEnabled: Bool
  let occupancyCooldown: TimeInterval
  /// Camera ID for standalone sensors when the camera accessory is off.
  let sensorCameraID: String?
  let sirenEnabled: Bool
  let buttonEnabled: Bool
  let hasBattery: Bool
}

/// Objects created off MainActor, returned to MainActor for callback wiring and UI updates.
private nonisolated struct ServerSetup: @unchecked Sendable {
  let bridge: HAPBridgeInfo
  let lightbulb: HAPAccessory
  let camera: HAPCameraAccessory
  let motionSensor: HAPMotionSensorAccessory
  let lightSensor: HAPLightSensorAccessory
  let contactSensor: HAPContactSensorAccessory
  let occupancySensor: HAPOccupancySensorAccessory
  let siren: HAPSirenAccessory
  let button: HAPButtonAccessory
  let server: HAPServer
  let fmp4Writer: FragmentedMP4Writer?
  let dataStream: HAPDataStream?
  let monitoringSession: MonitoringCaptureSession?
  let motionMonitor: MotionMonitor
  let ambientLightDetector: AmbientLightDetector?
  let occupancyDetector: OccupancySensor?
  let sirenPlayer: SirenPlayer?
  let isMotionAvailable: Bool
}

/// Creates the HAP server and all accessories off the main thread.
/// PairingStore (file I/O), DeviceIdentity (Keychain), and NWListener
/// creation are the heaviest operations moved off MainActor.
private nonisolated func createServerSetup(config: StartConfig) throws -> ServerSetup {
  let device = config.deviceModel  // "iPhone", "iPad", etc.
  let fw = HAPViewModel.firmwareVersion

  let bridge = HAPBridgeInfo(
    name: "Pylo Bridge", model: "\(device) Bridge", manufacturer: "Pylo",
    serialNumber: config.serial, firmwareRevision: fw
  )

  let lightbulb = HAPAccessory(
    aid: AccessoryID.lightbulb, name: "Pylo Flashlight", model: "\(device) Light",
    manufacturer: "Pylo", serialNumber: config.serial + "-light", firmwareRevision: fw
  )

  let camera = HAPCameraAccessory(
    aid: AccessoryID.camera, name: "Pylo Camera", model: "\(device) Camera",
    manufacturer: "Pylo", serialNumber: config.serial + "-cam", firmwareRevision: fw
  )

  let lightSensor = HAPLightSensorAccessory(
    aid: AccessoryID.lightSensor, name: "Pylo Light Sensor",
    model: "\(device) Light Sensor", manufacturer: "Pylo",
    serialNumber: config.serial + "-light-sensor", firmwareRevision: fw
  )

  let motionSensor = HAPMotionSensorAccessory(
    aid: AccessoryID.motionSensor, name: "Pylo Motion Sensor",
    model: "\(device) Motion Sensor", manufacturer: "Pylo",
    serialNumber: config.serial + "-motion", firmwareRevision: fw
  )

  let contactSensor = HAPContactSensorAccessory(
    aid: AccessoryID.contactSensor, name: "Pylo Contact Sensor",
    model: "\(device) Contact Sensor", manufacturer: "Pylo",
    serialNumber: config.serial + "-contact", firmwareRevision: fw
  )

  let occupancySensor = HAPOccupancySensorAccessory(
    aid: AccessoryID.occupancySensor, name: "Pylo Occupancy Sensor",
    model: "\(device) Occupancy Sensor", manufacturer: "Pylo",
    serialNumber: config.serial + "-occupancy", firmwareRevision: fw
  )

  let siren = HAPSirenAccessory(
    aid: AccessoryID.siren, name: "Pylo Siren", model: "\(device) Siren",
    manufacturer: "Pylo",
    serialNumber: config.serial + "-siren", firmwareRevision: fw
  )

  let button = HAPButtonAccessory(
    aid: AccessoryID.button, name: "Pylo Button",
    model: "\(device) Button", manufacturer: "Pylo",
    serialNumber: config.serial + "-button", firmwareRevision: fw
  )

  // File I/O and Keychain reads — the main motivation for running off MainActor
  // PairSetupHandler.keyStore is already set by PyloApp._ensureKeyStore on the
  // main thread before the server starts — no need to re-assign here.
  let pairingStore = PairingStore()
  let identity = DeviceIdentity(keyStore: PairSetupHandler.keyStore)

  // Build enabled accessories list
  var enabledAccessories: [any HAPAccessoryProtocol] = []
  if config.flashlightEnabled { enabledAccessories.append(lightbulb) }

  // fMP4 writer and data stream for HKSV
  var fmp4Writer: FragmentedMP4Writer?
  var dataStream: HAPDataStream?

  if config.selectedStreamCameraID != nil {
    camera.selectedCameraID = config.selectedStreamCameraID
    camera.minimumBitrate = config.minimumBitrate
    camera.microphoneEnabled = config.microphoneEnabled
    camera.hksvEnabled = true
    camera.videoMotionEnabled = true

    // Restore recordingActive from previous session so the hub doesn't
    // need to re-send the write after an app restart.
    let savedRecordingActive = UInt8(clamping: UserDefaults.standard.integer(forKey: "recordingActive"))
    if savedRecordingActive != 0 {
      camera.restoreRecordingActive(savedRecordingActive)
    }

    // Restore recordingAudioActive from previous session.
    let savedAudioActive = UInt8(clamping: UserDefaults.standard.integer(forKey: "recordingAudioActive"))
    if savedAudioActive != 0 {
      camera.restoreRecordingAudioActive(savedAudioActive)
    }

    // Restore selectedRecordingConfig from previous session.
    // The hub writes this once during initial HKSV setup and expects it to persist.
    // If it's not persisted, readCharacteristic returns nil (error status) which
    // should prompt the hub to re-write the configuration.
    if let savedConfig = UserDefaults.standard.data(forKey: "selectedRecordingConfig"),
      !savedConfig.isEmpty
    {
      camera.restoreSelectedRecordingConfig(savedConfig)
    }

    camera.onRecordingConfigChange = { [weak camera] active in
      if active { camera?.videoMotionEnabled = true }
      UserDefaults.standard.set(active ? 1 : 0, forKey: "recordingActive")
    }
    camera.onSelectedRecordingConfigChange = { config in
      UserDefaults.standard.set(config, forKey: "selectedRecordingConfig")
    }
    enabledAccessories.append(camera)

    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    fmp4Writer = writer
    camera.fragmentWriter = writer

    let ds = HAPDataStream()
    ds.fragmentWriter = writer
    dataStream = ds

    camera.onVideoMotionChange = { [weak camera, weak ds] detected in
      if detected {
        camera?.updateMotionDetected(true)
      } else {
        // Finish recording and send endOfStream BEFORE notifying hub that
        // motion cleared. Otherwise the hub closes the dataSend stream
        // when it receives MotionDetected=false, racing with our endOfStream.
        ds?.connection?.finishRecording { [weak camera] in
          camera?.updateMotionDetected(false)
        }
      }
    }
  }

  // Resolve the camera device for sensors that need it.
  // When the camera accessory is enabled, use its resolved camera.
  // Otherwise, resolve from the standalone sensor camera ID.
  let cameraDeviceForSensors: AVCaptureDevice? = {
    if config.selectedStreamCameraID != nil {
      return camera.resolvedCamera
    }
    if let sensorID = config.sensorCameraID,
      let device = AVCaptureDevice(uniqueID: sensorID)
    {
      return device
    }
    // Fallback to default wide-angle camera if the stored ID is missing or stale
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
  }()

  // Ambient light sensor — derives lux from AVCaptureDevice exposure metadata
  // on every frame (internally throttled by MonitoringCaptureSession).
  var ambientLightDetector: AmbientLightDetector?
  if config.lightSensorEnabled, AmbientLightDetector.isAvailable,
    let cameraDevice = cameraDeviceForSensors
  {
    let detector = AmbientLightDetector()
    detector.device = cameraDevice
    detector.onLuxChange = { [weak lightSensor] lux in
      lightSensor?.updateLux(lux)
    }
    if config.selectedStreamCameraID != nil {
      camera.ambientLightDetector = detector
    }
    ambientLightDetector = detector
    enabledAccessories.append(lightSensor)
  }

  // Occupancy sensor — uses Vision framework person detection on camera frames
  var occupancyDetector: OccupancySensor?
  if config.occupancyEnabled, cameraDeviceForSensors != nil {
    let detector = OccupancySensor()
    detector.cooldown = config.occupancyCooldown
    detector.onOccupancyChange = { [weak occupancySensor] detected in
      occupancySensor?.updateOccupancyDetected(detected)
    }
    occupancyDetector = detector
    enabledAccessories.append(occupancySensor)
  }

  if config.motionEnabled { enabledAccessories.append(motionSensor) }
  if config.contactEnabled { enabledAccessories.append(contactSensor) }

  // Siren player — uses AVAudioEngine to generate alarm tone
  var sirenPlayer: SirenPlayer?
  if config.sirenEnabled {
    let player = SirenPlayer()
    player.onActiveChange = { [weak siren] active in
      // Sync the HAP state if the siren stops externally
      if !active { siren?.updateOn(false) }
    }
    siren.onSirenActivate = { [weak player, weak camera, weak siren] on in
      if on {
        // Don't start the siren while the camera is streaming — the siren's
        // .playAndRecord audio session would clobber the camera's .voiceChat
        // session, breaking stream audio.
        guard camera?.streamSession == nil else {
          siren?.updateOn(false)
          return
        }
        player?.start()
      } else {
        player?.stop()
      }
    }
    sirenPlayer = player
    enabledAccessories.append(siren)
  }

  if config.buttonEnabled { enabledAccessories.append(button) }

  // Set a placeholder battery state on all accessories before server init
  // so the battery service is included in the c# hash. The actual values
  // are updated when BatteryMonitor wires in on MainActor.
  if config.hasBattery {
    let placeholder = BatteryState()
    lightbulb.batteryState = placeholder
    camera.batteryState = placeholder
    motionSensor.batteryState = placeholder
    lightSensor.batteryState = placeholder
    contactSensor.batteryState = placeholder
    occupancySensor.batteryState = placeholder
    siren.batteryState = placeholder
    button.batteryState = placeholder
  }

  // NWListener creation — also benefits from being off MainActor
  let server = try HAPServer(
    bridge: bridge, accessories: enabledAccessories,
    pairingStore: pairingStore, deviceIdentity: identity
  )

  // Start HDS listener and wire DataStream setup callback
  if let ds = dataStream {
    try? ds.startListener()
    server.dataStream = ds

    camera.onSetupDataStream = { [weak ds] requestData, sharedSecret, respond in
      guard let ds else { return }
      // Use the shared secret from the connection making this write,
      // not from an arbitrary connection (which could be a different session).
      guard let secret = sharedSecret else { return }
      respond(ds.setupTransport(requestTLV: requestData, sharedSecret: secret))
    }
  }

  // Monitoring capture session — needed for HKSV (when camera accessory is on)
  // and/or standalone sensors (light sensor, occupancy sensor).
  let needsStandaloneSensors =
    config.selectedStreamCameraID == nil
    && (ambientLightDetector != nil || occupancyDetector != nil)
  var monitoringSession: MonitoringCaptureSession?
  if config.selectedStreamCameraID != nil || needsStandaloneSensors {
    let monitoring = MonitoringCaptureSession()
    monitoringSession = monitoring

    if config.selectedStreamCameraID != nil {
      // Full mode: HKSV, fMP4, snapshots, all camera callbacks
      monitoring.fragmentWriter = fmp4Writer

      // Cache a JPEG snapshot from the monitoring session every ~1s so snapshot
      // requests from Home.app can be answered instantly instead of cold-starting
      // a new AVCaptureSession (which takes 1-3s and causes "No Response").
      // JPEG encoding is dispatched off captureQueue to avoid blocking frame
      // delivery (which would cause dropped frames and affect motion/lux detection).
      let ciContext = camera.snapshotCIContext
      let snapshotQueue = DispatchQueue(
        label: "\(Bundle.main.bundleIdentifier!).snapshot-encode", qos: .utility)
      monitoring.snapshotCallback = { [weak camera] pixelBuffer in
        // Render the CVPixelBuffer to a CGImage synchronously while the buffer
        // is still valid. AVFoundation may recycle the pixel buffer's backing
        // memory after this callback returns, so async access is unsafe.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        snapshotQueue.async { [weak camera] in
          let ciImageFromCG = CIImage(cgImage: cgImage)
          guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let jpeg = ciContext.jpegRepresentation(
              of: ciImageFromCG, colorSpace: colorSpace, options: [:])
          else { return }
          camera?.cachedSnapshot = jpeg
        }
      }

      let monitoringBusy = Locked(initialState: false)
      camera.onMonitoringCaptureNeeded = {
        [
          weak monitoring, weak camera, weak occupancyDetector,
          weak ambientLightDetector
        ] needed, existingSession in
        guard let camera else { return }
        // Re-entrancy guard: start() can synchronously deliver buffered frames
        // when reusing a handed-off session, which may re-trigger this callback
        // and cause a stack overflow.
        let reentrant = monitoringBusy.withLock { (busy: inout Bool) -> Bool in
          if busy { return true }
          busy = true
          return false
        }
        guard !reentrant else { return }
        defer { monitoringBusy.withLock { $0 = false } }
        if needed {
          monitoring?.videoMotionDetector = camera.videoMotionDetector
          monitoring?.ambientLightDetector = camera.ambientLightDetector ?? ambientLightDetector
          monitoring?.occupancySensor = occupancyDetector
          monitoring?.audioRecordingEnabled =
            camera.recordingAudioActive != 0 && camera.microphoneEnabled
          if let device = camera.resolvedCamera {
            monitoring?.start(camera: device, existingSession: existingSession)
          }
        } else if occupancyDetector != nil || ambientLightDetector != nil {
          // HKSV disarmed but sensors still need frames — restart
          // monitoring without HKSV-specific features (motion detection, audio).
          monitoring?.stop()
          camera.videoMotionDetector?.reset()
          monitoring?.videoMotionDetector = nil
          monitoring?.ambientLightDetector = ambientLightDetector
          monitoring?.occupancySensor = occupancyDetector
          monitoring?.audioRecordingEnabled = false
          if let device = camera.resolvedCamera {
            monitoring?.start(camera: device, existingSession: existingSession)
          }
        } else {
          monitoring?.stop()
          camera.videoMotionDetector?.reset()
        }
      }

      // Auto-start monitoring if recordingActive was restored from a previous session,
      // or if sensors need camera frames.
      if camera.streamSession == nil,
        camera.recordingActive != 0 || occupancyDetector != nil || ambientLightDetector != nil
      {
        let recordingArmed = camera.recordingActive != 0
        monitoring.videoMotionDetector = recordingArmed ? camera.videoMotionDetector : nil
        monitoring.ambientLightDetector =
          recordingArmed
          ? (camera.ambientLightDetector ?? ambientLightDetector) : ambientLightDetector
        monitoring.occupancySensor = occupancyDetector
        monitoring.audioRecordingEnabled =
          recordingArmed && camera.recordingAudioActive != 0 && camera.microphoneEnabled
        if let device = camera.resolvedCamera {
          monitoring.start(camera: device)
        }
      }

      // Restart monitoring when recordingAudioActive changes so audio state takes effect
      camera.onRecordingAudioActiveChange = { [weak monitoring, weak camera] active in
        UserDefaults.standard.set(active ? 1 : 0, forKey: "recordingAudioActive")
        if let camera, camera.recordingActive != 0, camera.streamSession == nil {
          monitoring?.stop()
          monitoring?.audioRecordingEnabled = active && camera.microphoneEnabled
          if let device = camera.resolvedCamera {
            monitoring?.start(camera: device)
          }
        }
      }
    } else {
      // Sensor-only mode: no HKSV, no fMP4, no snapshots — just run sensors
      monitoring.sensorOnly = true
      monitoring.ambientLightDetector = ambientLightDetector
      monitoring.occupancySensor = occupancyDetector
      monitoring.audioRecordingEnabled = false
      if let device = cameraDeviceForSensors {
        monitoring.start(camera: device)
      }
    }
  }

  // Stop the siren when camera streaming starts — the camera's voiceChat
  // audio session mode kills the siren's AVAudioEngine and it can't recover.
  camera.onStreamingStart = { [weak sirenPlayer, weak siren, weak lightbulb] in
    // Camera streaming takes over the capture device, killing the torch.
    if lightbulb?.isOn == true {
      lightbulb?.updateOn(false)
    }
    // The camera's voiceChat audio session mode kills the siren's AVAudioEngine.
    if sirenPlayer?.isPlaying == true {
      sirenPlayer?.stop()
      siren?.updateOn(false)
    }
  }

  // Hand off the monitoring session's AVCaptureSession to the stream session
  // for reuse, avoiding the ~500ms cold-start of creating a new one.
  camera.onMonitoringSessionHandoff = {
    [weak monitoringSession, weak camera, weak occupancyDetector] in
    camera?.videoMotionDetector?.reset()
    occupancyDetector?.reset()
    return monitoringSession?.handoff()
  }

  // Pause/resume the monitoring session around snapshot captures
  // so only one AVCaptureSession is active at a time (iOS limitation).
  camera.onSnapshotWillCapture = { [weak monitoringSession, weak camera, weak occupancyDetector] in
    monitoringSession?.stop()
    camera?.videoMotionDetector?.reset()
    occupancyDetector?.reset()
  }
  camera.onSnapshotDidCapture = {
    [
      weak monitoringSession, weak camera, weak occupancyDetector,
      weak ambientLightDetector
    ] in
    // Resume monitoring if recording armed or sensors need frames + no live stream
    if let camera, camera.streamSession == nil,
      camera.recordingActive != 0 || occupancyDetector != nil || ambientLightDetector != nil,
      let device = camera.resolvedCamera
    {
      let recordingArmed = camera.recordingActive != 0
      monitoringSession?.videoMotionDetector = recordingArmed ? camera.videoMotionDetector : nil
      monitoringSession?.ambientLightDetector =
        recordingArmed
        ? (camera.ambientLightDetector ?? ambientLightDetector) : ambientLightDetector
      monitoringSession?.occupancySensor = occupancyDetector
      monitoringSession?.audioRecordingEnabled =
        recordingArmed && camera.recordingAudioActive != 0 && camera.microphoneEnabled
      monitoringSession?.start(camera: device)
    }
  }

  let motionMonitor = MotionMonitor()
  motionMonitor.threshold = config.motionThreshold
  motionMonitor.onMotionChange = { [weak motionSensor] detected in
    motionSensor?.updateMotionDetected(detected)
  }

  return ServerSetup(
    bridge: bridge, lightbulb: lightbulb, camera: camera,
    motionSensor: motionSensor, lightSensor: lightSensor,
    contactSensor: contactSensor,
    occupancySensor: occupancySensor,
    siren: siren,
    button: button,
    server: server, fmp4Writer: fmp4Writer, dataStream: dataStream,
    monitoringSession: monitoringSession,
    motionMonitor: motionMonitor,
    ambientLightDetector: ambientLightDetector,
    occupancyDetector: occupancyDetector,
    sirenPlayer: sirenPlayer,
    isMotionAvailable: motionMonitor.isAvailable
  )
}

// MARK: - Platform Helpers

/// Returns a stable device serial string.
@MainActor private func deviceSerial() -> String {
  #if os(iOS)
    return UIDevice.current.identifierForVendor?.uuidString ?? "000000"
  #elseif os(macOS)
    // Use the hardware UUID as a stable identifier
    let platformExpert = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard platformExpert != IO_OBJECT_NULL else { return "000000" }
    defer { IOObjectRelease(platformExpert) }
    if let uuidCF = IORegistryEntryCreateCFProperty(
      platformExpert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
    {
      return (uuidCF.takeRetainedValue() as? String) ?? "000000"
    }
    return "000000"
  #endif
}

/// Returns a human-readable device model name.
@MainActor private func deviceModelName() -> String {
  #if os(iOS)
    return UIDevice.current.model  // "iPhone", "iPad", etc.
  #elseif os(macOS)
    return "Mac"
  #endif
}

// MARK: - HomeKit QR Code Helpers

/// Build the `X-HM://` setup URI defined by the HAP spec (§8.6.1).
/// The payload is a 45-bit integer, base-36 encoded and zero-padded to 9 chars:
///   bits  0–26: setup code as plain integer (digits without dashes)
///   bits 27–30: accessory category (4 bits)
///   bits 31–34: status flags (4 bits, 2 = IP)
///   bits 35–44: reserved / version (0)
nonisolated func hapSetupURI(
  setupCode: String, category: Int = HAPAccessoryCategory.bridge.rawValue,
  setupID: String
)
  -> String
{
  let digits = setupCode.filter(\.isWholeNumber)
  guard let code = UInt64(digits),
    setupID.count == 4,
    setupID.allSatisfy(\.isASCII)
  else { return "" }
  let flags: UInt64 = 2  // IP accessory
  var payload: UInt64 = 0
  payload |= code
  payload |= UInt64(category) << 27
  payload |= flags << 31

  // Base-36 encode, uppercase, zero-padded to 9 characters
  var encoded = String(payload, radix: 36, uppercase: true)
  while encoded.count < 9 { encoded = "0" + encoded }
  return "X-HM://\(encoded)\(setupID)"
}

/// Generate a crisp QR code CGImage from a string using CoreImage.
/// Called from a detached Task (off MainActor). Returns CGImage (Sendable)
/// so the caller can wrap it in a platform image on the main actor.
/// CIContext is thread-safe and expensive to create — reuse a single instance.
nonisolated private let _qrContext = CIContext()
nonisolated func generateQRCodeCG(from string: String) -> CGImage? {
  let context = _qrContext
  let filter = CIFilter.qrCodeGenerator()
  filter.message = Data(string.utf8)
  filter.correctionLevel = "M"
  guard let output = filter.outputImage else { return nil }
  let scale = CGAffineTransform(scaleX: 10, y: 10)
  let scaled = output.transformed(by: scale)
  return context.createCGImage(scaled, from: scaled.extent)
}
