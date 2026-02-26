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
          viewModel.start()
        }
    }
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
      guard oldValue?.id != selectedCamera?.id else { return }
      let wasNone = oldValue == nil
      let isNone = selectedCamera == nil
      if let selectedCamera {
        UserDefaults.standard.set(selectedCamera.id, forKey: "selectedCameraID")
        lightMonitor?.restart(with: selectedCamera)
      } else {
        UserDefaults.standard.set("none", forKey: "selectedCameraID")
        lightMonitor?.stop()
      }
      if isRunning && wasNone != isNone { needsRestart = true }
    }
  }
  var selectedStreamCamera: CameraOption? {
    didSet {
      guard oldValue?.id != selectedStreamCamera?.id else { return }
      let wasNone = oldValue == nil
      let isNone = selectedStreamCamera == nil
      if let selectedStreamCamera {
        UserDefaults.standard.set(selectedStreamCamera.id, forKey: "selectedStreamCameraID")
        cameraAccessory?.selectedCameraID = selectedStreamCamera.id
      } else {
        UserDefaults.standard.set("none", forKey: "selectedStreamCameraID")
        cameraAccessory?.selectedCameraID = nil
      }
      if isRunning && wasNone != isNone { needsRestart = true }
    }
  }
  var flashlightEnabled: Bool = true {
    didSet {
      guard flashlightEnabled != oldValue else { return }
      UserDefaults.standard.set(flashlightEnabled, forKey: "flashlightEnabled")
      if isRunning { needsRestart = true }
    }
  }
  var motionEnabled: Bool = true {
    didSet {
      guard motionEnabled != oldValue else { return }
      UserDefaults.standard.set(motionEnabled, forKey: "motionEnabled")
      if motionEnabled {
        motionMonitor?.start()
      } else {
        motionMonitor?.stop()
        isMotionDetected = false
      }
      if isRunning { needsRestart = true }
    }
  }
  var videoQuality: VideoQuality = .medium {
    didSet {
      guard videoQuality != oldValue else { return }
      UserDefaults.standard.set(videoQuality.rawValue, forKey: "videoQuality")
      cameraAccessory?.minimumBitrate = videoQuality.minimumBitrate
    }
  }
  // NOTE: iOS does not offer a background mode suitable for a HAP server.
  // The app cannot run indefinitely in the background, so keeping the screen
  // awake (opt-in) is the best available workaround to stay reachable.
  var keepScreenAwake: Bool = false {
    didSet {
      guard keepScreenAwake != oldValue else { return }
      UserDefaults.standard.set(keepScreenAwake, forKey: "keepScreenAwake")
      UIApplication.shared.isIdleTimerDisabled = keepScreenAwake && isRunning
    }
  }

  /// Whether the accessory configuration has changed since the server started.
  var needsRestart = false

  @ObservationIgnored private var server: HAPServer?
  @ObservationIgnored private var lightMonitor: AmbientLightMonitor?
  @ObservationIgnored private var motionMonitor: MotionMonitor?
  @ObservationIgnored private var batteryMonitor: BatteryMonitor?
  @ObservationIgnored private var cameraAccessory: HAPCameraAccessory?

  @MainActor
  func start() {
    guard !isRunning && !isStarting else { return }
    isStarting = true
    needsRestart = false
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

      // Restore accessory-enable preferences (default to true)
      if UserDefaults.standard.object(forKey: "flashlightEnabled") != nil {
        self.flashlightEnabled = UserDefaults.standard.bool(forKey: "flashlightEnabled")
      }
      if UserDefaults.standard.object(forKey: "motionEnabled") != nil {
        self.motionEnabled = UserDefaults.standard.bool(forKey: "motionEnabled")
      }

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

      // Discover available cameras; restore previous selections
      let cameras = CameraOption.availableCameras()
      self.availableCameras = cameras
      if self.selectedCamera == nil {
        let savedID = UserDefaults.standard.string(forKey: "selectedCameraID")
        if savedID == "none" {
          // User explicitly chose "None" — leave selectedCamera nil
        } else {
          self.selectedCamera =
            cameras.first(where: { $0.id == savedID })
            ?? cameras.first { $0.name.localizedCaseInsensitiveContains("front") }
            ?? cameras.first
        }
      }
      if self.selectedStreamCamera == nil {
        let savedID = UserDefaults.standard.string(forKey: "selectedStreamCameraID")
        if savedID == "none" {
          // User explicitly chose "None" — leave selectedStreamCamera nil
        } else {
          self.selectedStreamCamera =
            cameras.first(where: { $0.id == savedID })
            ?? cameras.first { $0.name.localizedCaseInsensitiveContains("back") }
            ?? cameras.first
        }
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
        if let savedQuality = UserDefaults.standard.string(forKey: "videoQuality"),
          let quality = VideoQuality(rawValue: savedQuality)
        {
          self.videoQuality = quality
        }
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
          self?.hasPairings = pairingStore.isPaired
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
        self.isRunning = true
        self.isStarting = false
        self.statusMessage = "Advertising as '\(bridge.name)'\nDevice ID: \(identity.deviceID)"

        // Start ambient light monitoring with selected camera (if any)
        if self.selectedCamera != nil {
          monitor.start(with: self.selectedCamera)
        }

        // Start motion monitoring if enabled
        if self.motionEnabled {
          motion.start()
        }

        // Restore keep-screen-awake preference
        self.keepScreenAwake = UserDefaults.standard.bool(forKey: "keepScreenAwake")
        UIApplication.shared.isIdleTimerDisabled = self.keepScreenAwake
      } catch {
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
    isRunning = false
    UIApplication.shared.isIdleTimerDisabled = false
    statusMessage = "Stopped"
  }

  @MainActor
  func resetPairings() {
    server?.pairingStore.removeAll()
    server?.updateAdvertisement()
    hasPairings = false
    statusMessage = "Pairings cleared — ready for new pairing"
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
private func generateQRCode(from string: String) -> UIImage? {
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

// MARK: - Burn-in Prevention

/// Seconds of inactivity before the screen dims to black.
private let screenDimDelay: TimeInterval = 120

struct ContentView: View {
  @Bindable var viewModel: HAPViewModel
  @State private var isScreenDimmed = false
  @State private var dimTask: Task<Void, Never>?
  @State private var qrImage: UIImage?

  private func resetDimTimer() {
    dimTask?.cancel()
    isScreenDimmed = false
    guard viewModel.isRunning else { return }
    dimTask = Task {
      try? await Task.sleep(for: .seconds(screenDimDelay))
      guard !Task.isCancelled else { return }
      isScreenDimmed = true
    }
  }

  var body: some View {
    ZStack {
      mainContent
        .allowsHitTesting(!isScreenDimmed)

      if isScreenDimmed {
        Color.black
          .ignoresSafeArea()
          .onTapGesture { resetDimTimer() }
      }
    }
    .onChange(of: viewModel.isRunning) {
      if viewModel.isRunning {
        resetDimTimer()
        qrImage = generateQRCode(from: hapSetupURI(setupCode: viewModel.setupCode))
      } else {
        dimTask?.cancel()
        dimTask = nil
        isScreenDimmed = false
      }
    }
  }

  private var mainContent: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 24) {
          Text("Pylo")
            .font(.largeTitle)
            .fontWeight(.bold)

          // Status
          GroupBox("Status") {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                if viewModel.isStarting {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  Circle()
                    .fill(viewModel.isRunning ? .green : .gray)
                    .frame(width: 12, height: 12)
                }
                Text(
                  viewModel.isStarting ? "Starting…" : viewModel.isRunning ? "Running" : "Stopped")
              }
              Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
              if viewModel.needsRestart {
                Text("Restart required for accessory changes to take effect")
                  .font(.caption)
                  .foregroundColor(.orange)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          // Settings
          if viewModel.isRunning {
            GroupBox("Settings") {
              Toggle("Keep Screen Awake", isOn: $viewModel.keepScreenAwake)
            }
          }

          // Setup Code + QR
          if viewModel.isRunning {
            GroupBox("Setup Code") {
              VStack(spacing: 12) {
                if let qr = qrImage {
                  Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                }
                Text(viewModel.setupCode)
                  .font(.system(.title, design: .monospaced))
                  .fontWeight(.bold)
                  .frame(maxWidth: .infinity)
                Text("Scan with Home.app or enter the code manually")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }

          // Light State
          if viewModel.isRunning {
            GroupBox("Flashlight") {
              VStack(spacing: 12) {
                if viewModel.flashlightEnabled {
                  Image(systemName: viewModel.isLightOn ? "lightbulb.fill" : "lightbulb")
                    .font(.system(size: 48))
                    .foregroundColor(viewModel.isLightOn ? .yellow : .gray)

                  Text(viewModel.isLightOn ? "ON" : "OFF")
                    .font(.headline)

                  if viewModel.isLightOn {
                    Text("Brightness: \(viewModel.brightness)%")
                      .font(.subheadline)
                      .foregroundColor(.secondary)
                  }
                } else {
                  Image(systemName: "lightbulb.slash")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)

                  Text("Disabled")
                    .font(.headline)
                }

                Toggle("Enabled", isOn: $viewModel.flashlightEnabled)
              }
              .frame(maxWidth: .infinity)
            }

            GroupBox("Ambient Light") {
              VStack(spacing: 8) {
                if viewModel.selectedCamera == nil {
                  Image(systemName: "sun.max")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                  Text("Disabled")
                    .font(.headline)
                } else {
                  Image(systemName: "sun.max")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                  Text(String(format: "%.1f lux", viewModel.ambientLux))
                    .font(.system(.title2, design: .monospaced))
                }

                Picker("Camera", selection: $viewModel.selectedCamera) {
                  Text("None").tag(CameraOption?.none)
                  ForEach(viewModel.availableCameras) { camera in
                    Text(camera.name).tag(Optional(camera))
                  }
                }
                .pickerStyle(.menu)
              }
              .frame(maxWidth: .infinity)
            }

            GroupBox("Motion Sensor") {
              VStack(spacing: 8) {
                if !viewModel.motionEnabled {
                  Image(systemName: "figure.stand")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                  Text("Disabled")
                    .font(.headline)
                } else if viewModel.isMotionAvailable {
                  Image(
                    systemName: viewModel.isMotionDetected ? "figure.walk.motion" : "figure.stand"
                  )
                  .font(.system(size: 32))
                  .foregroundColor(viewModel.isMotionDetected ? .blue : .gray)
                  Text(viewModel.isMotionDetected ? "Motion Detected" : "No Motion")
                    .font(.headline)
                  Text("Accelerometer movement")
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else {
                  Image(systemName: "figure.stand")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                  Text("No accelerometer found")
                    .font(.headline)
                  Text("An accelerometer is required for motion sensing")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Toggle("Enabled", isOn: $viewModel.motionEnabled)
              }
              .frame(maxWidth: .infinity)
            }

            GroupBox("Camera") {
              VStack(spacing: 8) {
                if viewModel.availableCameras.isEmpty {
                  Image(systemName: "video.slash")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                  Text("No cameras found")
                    .font(.headline)
                  Text("A camera is required for HomeKit streaming")
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else if viewModel.selectedStreamCamera == nil {
                  Image(systemName: "video.slash")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                  Text("Disabled")
                    .font(.headline)

                  Picker("Camera", selection: $viewModel.selectedStreamCamera) {
                    Text("None").tag(CameraOption?.none)
                    ForEach(viewModel.availableCameras) { camera in
                      Text(camera.name).tag(Optional(camera))
                    }
                  }
                  .pickerStyle(.menu)
                } else {
                  Image(systemName: viewModel.isCameraStreaming ? "video.fill" : "video")
                    .font(.system(size: 32))
                    .foregroundColor(viewModel.isCameraStreaming ? .green : .gray)
                  Text(viewModel.isCameraStreaming ? "Streaming" : "Idle")
                    .font(.headline)

                  Picker("Camera", selection: $viewModel.selectedStreamCamera) {
                    Text("None").tag(CameraOption?.none)
                    ForEach(viewModel.availableCameras) { camera in
                      Text(camera.name).tag(Optional(camera))
                    }
                  }
                  .pickerStyle(.menu)

                  Picker("Quality", selection: $viewModel.videoQuality) {
                    ForEach(VideoQuality.allCases) { quality in
                      Text(quality.rawValue).tag(quality)
                    }
                  }
                  .pickerStyle(.segmented)

                  Text(viewModel.selectedStreamCamera?.name ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
              }
              .frame(maxWidth: .infinity)
            }
          }
        }
        .padding()
      }

      // Buttons (pinned to bottom)
      VStack(spacing: 8) {
        if viewModel.isRunning && viewModel.hasPairings {
          Button(action: { viewModel.resetPairings() }) {
            Text("Reset Pairings")
              .font(.subheadline)
              .frame(maxWidth: .infinity)
              .padding(10)
              .background(Color.orange)
              .foregroundColor(.white)
              .clipShape(.rect(cornerRadius: 10))
          }
        }

        Button(action: {
          if viewModel.isRunning {
            viewModel.stop()
          } else {
            viewModel.start()
          }
        }) {
          Group {
            if viewModel.isStarting {
              HStack(spacing: 8) {
                ProgressView()
                  .tint(.white)
                Text("Starting…")
              }
            } else {
              Text(viewModel.isRunning ? "Stop Server" : "Start Server")
            }
          }
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding()
          .background(
            viewModel.isStarting ? Color.gray : viewModel.isRunning ? Color.red : Color.blue
          )
          .foregroundColor(.white)
          .clipShape(.rect(cornerRadius: 12))
        }
        .disabled(viewModel.isStarting)
      }
      .padding()
    }
    .onTapGesture { resetDimTimer() }
  }
}
