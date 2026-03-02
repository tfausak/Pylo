import CoreImage.CIFilterBuiltins
import FragmentedMP4
import HAP
import SwiftUI

// MARK: - Accessory Config Snapshot

/// Captures the accessory-enable state at server start so we can detect
/// whether settings have actually diverged (not just toggled and toggled back).
struct AccessoryConfig: Equatable {
  var flashlightEnabled: Bool
  var selectedCameraID: String?
  var motionEnabled: Bool

  init(
    flashlightEnabled: Bool, selectedCameraID: String?,
    motionEnabled: Bool
  ) {
    self.flashlightEnabled = flashlightEnabled
    self.selectedCameraID = selectedCameraID
    self.motionEnabled = motionEnabled
  }

  init(from vm: HAPViewModel) {
    flashlightEnabled = vm.flashlightEnabled
    selectedCameraID = vm.selectedStreamCamera?.id
    motionEnabled = vm.motionEnabled
  }
}

// MARK: - View Model

@Observable @MainActor
final class HAPViewModel {

  init() {
    restorePreferences()
  }

  var isRunning = false
  var isStarting = false
  var isLightOn = false
  var brightness: Int = 100
  var isPaired = false
  var statusMessage = "Tap Start to begin"
  var setupCode = PairSetupHandler.setupCode
  var isMotionDetected = false
  var isMotionAvailable = false
  var isCameraStreaming = false
  var hasPairings = false
  var availableCameras: [CameraOption] = []
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

  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var startGeneration = 0
  @ObservationIgnored private var server: HAPServer?
  @ObservationIgnored private var motionMonitor: MotionMonitor?
  @ObservationIgnored private var batteryMonitor: BatteryMonitor?
  @ObservationIgnored private var cameraAccessory: HAPCameraAccessory?
  @ObservationIgnored private var monitoringSession: MonitoringCaptureSession?
  @ObservationIgnored private var fragmentWriter: FragmentedMP4Writer?
  @ObservationIgnored private var dataStreamHandler: HAPDataStream?

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

    // Discover available cameras and restore stream camera selection
    let cameras = CameraOption.availableCameras()
    availableCameras = cameras
    let savedStreamID = UserDefaults.standard.string(forKey: "selectedStreamCameraID")
    if savedStreamID == "none" {
      selectedStreamCamera = nil
    } else {
      selectedStreamCamera =
        cameras.first(where: { $0.id == savedStreamID })
        ?? cameras.first { $0.name.localizedCaseInsensitiveContains("back") }
        ?? cameras.first
    }
    hasPairings = UserDefaults.standard.bool(forKey: "hasPairings")
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

    // Stage 1: Capture config values on MainActor before leaving isolation.
    let config = StartConfig(
      serial: UIDevice.current.identifierForVendor?.uuidString ?? "000000",
      flashlightEnabled: flashlightEnabled,
      selectedStreamCameraID: selectedStreamCamera?.id,
      motionEnabled: motionEnabled,
      motionThreshold: motionSensitivity.threshold,
      minimumBitrate: videoQuality.minimumBitrate
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
          self.statusMessage = "Failed to start: \(error.localizedDescription)"
        }
        return
      }

      guard !Task.isCancelled, self.startGeneration == myGeneration else {
        setup.server.stop()
        setup.dataStream?.stop()
        setup.monitoringSession?.stop()
        setup.fmp4Writer?.stop()
        return
      }

      // Stage 3: Wire UI-updating callbacks, store references, and start
      // monitors — all on MainActor.
      self.server = setup.server
      self.monitoringSession = setup.monitoringSession
      self.motionMonitor = setup.motionMonitor
      self.cameraAccessory = config.selectedStreamCameraID != nil ? setup.camera : nil
      self.fragmentWriter = setup.fmp4Writer
      self.dataStreamHandler = setup.dataStream
      self.isMotionAvailable = setup.isMotionAvailable

      // Wire state-change callbacks that update published UI state
      var enabledAccessories: [any HAPAccessoryProtocol] = []

      if config.flashlightEnabled {
        setup.lightbulb.onStateChange = {
          [weak self, weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
          Task { @MainActor [weak self] in
            guard let self else { return }
            if iid == HAPAccessory.iidOn, case .bool(let on) = value {
              self.isLightOn = on
            } else if iid == HAPAccessory.iidBrightness, case .int(let b) = value {
              self.brightness = b
            }
          }
        }
        enabledAccessories.append(setup.lightbulb)
      }

      if config.selectedStreamCameraID != nil {
        setup.camera.onStateChange = {
          [weak self, weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
          Task { @MainActor [weak self] in
            guard let self else { return }
            if iid == HAPCameraAccessory.iidStreamingStatus,
              case .string(let b64) = value,
              let data = Data(base64Encoded: b64), data.count >= 3
            {
              self.isCameraStreaming = data[data.startIndex + 2] == 1
            }
          }
        }
        enabledAccessories.append(setup.camera)
      }

      if config.motionEnabled {
        setup.motionSensor.onStateChange = {
          [weak self, weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
          Task { @MainActor [weak self] in
            guard let self else { return }
            if iid == HAPMotionSensorAccessory.iidMotionDetected,
              case .bool(let detected) = value
            {
              self.isMotionDetected = detected
            }
          }
        }
        enabledAccessories.append(setup.motionSensor)
      }

      if config.selectedStreamCameraID != nil {
        setup.lightSensor.onStateChange = { [weak server = setup.server] aid, iid, value in
          server?.notifySubscribers(aid: aid, iid: iid, value: value)
        }
        enabledAccessories.append(setup.lightSensor)
      }

      setup.server.pairingStore.onChange = { [weak self, weak server = setup.server] in
        let isPaired = server?.pairingStore.isPaired ?? false
        UserDefaults.standard.set(isPaired, forKey: "hasPairings")
        Task { @MainActor [weak self] in
          withAnimation { self?.hasPairings = isPaired }
        }
      }

      // Battery monitor — uses UIDevice which requires MainActor
      let battery = BatteryMonitor()
      battery.start()
      if battery.isAvailable {
        let sharedBatteryState = battery.currentState()
        setup.lightbulb.batteryState = sharedBatteryState
        setup.camera.batteryState = sharedBatteryState
        setup.motionSensor.batteryState = sharedBatteryState
        setup.lightSensor.batteryState = sharedBatteryState

        battery.onBatteryChange = { [weak server = setup.server] state in
          sharedBatteryState.update(
            level: state.level,
            chargingState: state.chargingState,
            statusLowBattery: state.statusLowBattery)
          guard let server else { return }
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
      UserDefaults.standard.set(true, forKey: "hasStartedBefore")

      if config.motionEnabled {
        setup.motionMonitor.start()
      }
      UIApplication.shared.isIdleTimerDisabled = self.keepScreenAwake
    }
  }

  @MainActor
  func stop() {
    startGeneration += 1
    startTask?.cancel()
    startTask = nil
    isStarting = false
    batteryMonitor?.stop()
    batteryMonitor = nil
    motionMonitor?.stop()
    motionMonitor = nil
    fragmentWriter?.stop()
    fragmentWriter = nil
    monitoringSession?.stop()
    monitoringSession = nil
    dataStreamHandler?.stop()
    dataStreamHandler = nil
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
    UserDefaults.standard.set(false, forKey: "hasPairings")
    withAnimation { hasPairings = false }
  }
}

// MARK: - Server Setup (off MainActor)

/// Configuration captured from @MainActor properties for off-main-thread server creation.
private struct StartConfig: Sendable {
  let serial: String
  let flashlightEnabled: Bool
  let selectedStreamCameraID: String?
  let motionEnabled: Bool
  let motionThreshold: Double
  let minimumBitrate: Int
}

/// Objects created off MainActor, returned to MainActor for callback wiring and UI updates.
private struct ServerSetup: @unchecked Sendable {
  let bridge: HAPBridgeInfo
  let lightbulb: HAPAccessory
  let camera: HAPCameraAccessory
  let motionSensor: HAPMotionSensorAccessory
  let lightSensor: HAPLightSensorAccessory
  let server: HAPServer
  let fmp4Writer: FragmentedMP4Writer?
  let dataStream: HAPDataStream?
  let monitoringSession: MonitoringCaptureSession?
  let motionMonitor: MotionMonitor
  let ambientLightDetector: AmbientLightDetector?
  let isMotionAvailable: Bool
}

/// Creates the HAP server and all accessories off the main thread.
/// PairingStore (file I/O), DeviceIdentity (Keychain), and NWListener
/// creation are the heaviest operations moved off MainActor.
private nonisolated func createServerSetup(config: StartConfig) throws -> ServerSetup {
  let bridge = HAPBridgeInfo(
    name: "Pylo Bridge", model: "HAP-PoC", manufacturer: "DIY",
    serialNumber: config.serial, firmwareRevision: "0.1.0"
  )

  let lightbulb = HAPAccessory(
    aid: 2, name: "Pylo Flashlight", model: "HAP-PoC", manufacturer: "DIY",
    serialNumber: config.serial + "-light", firmwareRevision: "0.1.0"
  )

  let camera = HAPCameraAccessory(
    aid: 3, name: "Pylo Camera", model: "HAP-PoC", manufacturer: "DIY",
    serialNumber: config.serial + "-cam", firmwareRevision: "0.1.0"
  )

  let lightSensor = HAPLightSensorAccessory(
    aid: 4, name: "Pylo Light Sensor", model: "HAP-PoC", manufacturer: "DIY",
    serialNumber: config.serial + "-light-sensor", firmwareRevision: "0.1.0"
  )

  let motionSensor = HAPMotionSensorAccessory(
    aid: 5, name: "Pylo Motion Sensor", model: "HAP-PoC", manufacturer: "DIY",
    serialNumber: config.serial + "-motion", firmwareRevision: "0.1.0"
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
    camera.hksvEnabled = true
    camera.videoMotionEnabled = true

    // Restore recordingActive from previous session so the hub doesn't
    // need to re-send the write after an app restart.
    let savedRecordingActive = UInt8(UserDefaults.standard.integer(forKey: "recordingActive"))
    if savedRecordingActive != 0 {
      camera.restoreRecordingActive(savedRecordingActive)
    }

    // Restore recordingAudioActive from previous session.
    let savedAudioActive = UInt8(UserDefaults.standard.integer(forKey: "recordingAudioActive"))
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
    writer.configure(width: 1920, height: 1080, fps: 30)
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

  // Ambient light sensor — auto-enabled when camera is enabled, derives lux
  // from AVCaptureDevice exposure metadata on every frame (internally throttled).
  var ambientLightDetector: AmbientLightDetector?
  if config.selectedStreamCameraID != nil {
    let detector = AmbientLightDetector()
    detector.device = camera.resolvedCamera
    detector.onLuxChange = { [weak lightSensor] lux in
      lightSensor?.updateLux(lux)
    }
    camera.ambientLightDetector = detector
    ambientLightDetector = detector
    enabledAccessories.append(lightSensor)
  }

  if config.motionEnabled { enabledAccessories.append(motionSensor) }

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

  // Monitoring capture session for HKSV idle motion detection + fMP4 pre-buffering
  var monitoringSession: MonitoringCaptureSession?
  if config.selectedStreamCameraID != nil {
    let monitoring = MonitoringCaptureSession()
    monitoring.fragmentWriter = fmp4Writer
    monitoringSession = monitoring

    camera.onMonitoringCaptureNeeded = { [weak monitoring, weak camera] needed in
      guard let camera else { return }
      if needed {
        monitoring?.videoMotionDetector = camera.videoMotionDetector
        monitoring?.ambientLightDetector = camera.ambientLightDetector
        monitoring?.audioRecordingEnabled = camera.recordingAudioActive != 0
        if let device = camera.resolvedCamera {
          monitoring?.start(camera: device)
        }
      } else {
        monitoring?.stop()
        camera.videoMotionDetector?.reset()
      }
    }

    // Auto-start monitoring if recordingActive was restored from a previous session
    if camera.recordingActive != 0, camera.streamSession == nil {
      monitoring.videoMotionDetector = camera.videoMotionDetector
      monitoring.ambientLightDetector = camera.ambientLightDetector
      monitoring.audioRecordingEnabled = camera.recordingAudioActive != 0
      if let device = camera.resolvedCamera {
        monitoring.start(camera: device)
      }
    }

    // Restart monitoring when recordingAudioActive changes so audio state takes effect
    camera.onRecordingAudioActiveChange = { [weak monitoring, weak camera] active in
      UserDefaults.standard.set(active ? 1 : 0, forKey: "recordingAudioActive")
      if let camera, camera.recordingActive != 0, camera.streamSession == nil {
        monitoring?.stop()
        monitoring?.audioRecordingEnabled = active
        if let device = camera.resolvedCamera {
          monitoring?.start(camera: device)
        }
      }
    }
  }

  // Pause/resume the monitoring session around snapshot captures
  // so only one AVCaptureSession is active at a time (iOS limitation).
  camera.onSnapshotWillCapture = { [weak monitoringSession, weak camera] in
    monitoringSession?.stop()
    camera?.videoMotionDetector?.reset()
  }
  camera.onSnapshotDidCapture = { [weak monitoringSession, weak camera] in
    // Resume monitoring if recording armed + no live stream
    if let camera, camera.recordingActive != 0, camera.streamSession == nil,
      let device = camera.resolvedCamera
    {
      monitoringSession?.videoMotionDetector = camera.videoMotionDetector
      monitoringSession?.ambientLightDetector = camera.ambientLightDetector
      monitoringSession?.audioRecordingEnabled = camera.recordingAudioActive != 0
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
    server: server, fmp4Writer: fmp4Writer, dataStream: dataStream,
    monitoringSession: monitoringSession,
    motionMonitor: motionMonitor,
    ambientLightDetector: ambientLightDetector,
    isMotionAvailable: motionMonitor.isAvailable
  )
}

// MARK: - HomeKit QR Code Helpers

/// Build the `X-HM://` setup URI defined by the HAP spec (§8.6.1).
/// The payload is a 45-bit integer, base-36 encoded and zero-padded to 9 chars:
///   bits  0–26: setup code as plain integer (digits without dashes)
///   bits 27–30: accessory category (4 bits)
///   bits 31–34: status flags (4 bits, 2 = IP)
///   bits 35–44: reserved / version (0)
func hapSetupURI(
  setupCode: String, category: Int = HAPAccessoryCategory.bridge.rawValue,
  setupID: String? = nil
)
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
  return "X-HM://\(encoded)\(setupID ?? PairSetupHandler.setupID)"
}

/// Generate a crisp QR code `UIImage` from a string using CoreImage.
private let _qrContext = CIContext()
func generateQRCode(from string: String) -> UIImage? {
  let context = _qrContext
  let filter = CIFilter.qrCodeGenerator()
  filter.message = Data(string.utf8)
  filter.correctionLevel = "M"
  guard let output = filter.outputImage else { return nil }
  let scale = CGAffineTransform(scaleX: 10, y: 10)
  let scaled = output.transformed(by: scale)
  guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
  return UIImage(cgImage: cgImage)
}
