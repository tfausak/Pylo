import Combine
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
  @StateObject private var viewModel = HAPViewModel()

  init() {
    #if os(iOS)
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

final class HAPViewModel: ObservableObject {

  @Published var isRunning = false
  @Published var isStarting = false
  @Published var isLightOn = false
  @Published var brightness: Int = 100
  @Published var isPaired = false
  @Published var statusMessage = "Tap Start to begin"
  @Published var setupCode = PairSetupHandler.setupCode
  @Published var ambientLux: Float = 1.0
  @Published var isMotionDetected = false
  @Published var isMotionAvailable = false
  @Published var isCameraStreaming = false
  @Published var hasPairings = false
  @Published var availableCameras: [CameraOption] = []
  @Published var selectedCamera: CameraOption? {
    didSet {
      guard let selectedCamera, oldValue?.id != selectedCamera.id else { return }
      UserDefaults.standard.set(selectedCamera.id, forKey: "selectedCameraID")
      lightMonitor?.restart(with: selectedCamera)
    }
  }
  @Published var selectedStreamCamera: CameraOption? {
    didSet {
      guard let selectedStreamCamera, oldValue?.id != selectedStreamCamera.id else { return }
      UserDefaults.standard.set(selectedStreamCamera.id, forKey: "selectedStreamCameraID")
      cameraAccessory?.selectedCameraID = selectedStreamCamera.id
    }
  }
  @Published var videoQuality: VideoQuality = .medium {
    didSet {
      guard videoQuality != oldValue else { return }
      UserDefaults.standard.set(videoQuality.rawValue, forKey: "videoQuality")
      cameraAccessory?.minimumBitrate = videoQuality.minimumBitrate
    }
  }

  private var server: HAPServer?
  private var lightMonitor: AmbientLightMonitor?
  private var motionMonitor: MotionMonitor?
  private var cameraAccessory: HAPCameraAccessory?

  @MainActor
  func start() {
    guard !isRunning && !isStarting else { return }
    isStarting = true
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

      // Wire up state change callbacks
      lightbulb.onStateChange = { [weak self] aid, iid, value in
        Task { @MainActor in
          guard let self else { return }
          if iid == 9, let on = value as? Bool {
            self.isLightOn = on
          } else if iid == 10, let brightness = value as? Int {
            self.brightness = brightness
          }
          self.server?.notifySubscribers(aid: aid, iid: iid, value: value)
        }
      }

      lightSensor.onStateChange = { [weak self] aid, iid, value in
        Task { @MainActor in
          guard let self else { return }
          if iid == 9, let lux = value as? Float {
            self.ambientLux = lux
          }
          self.server?.notifySubscribers(aid: aid, iid: iid, value: value)
        }
      }

      motionSensor.onStateChange = { [weak self] aid, iid, value in
        Task { @MainActor in
          guard let self else { return }
          if iid == 9, let detected = value as? Bool {
            self.isMotionDetected = detected
          }
          self.server?.notifySubscribers(aid: aid, iid: iid, value: value)
        }
      }

      camera.onStateChange = { [weak self] aid, iid, value in
        Task { @MainActor in
          guard let self else { return }
          if iid == 14 {  // StreamingStatus changed
            // Check if streaming (base64 TLV8 with status byte)
            if let b64 = value as? String, let data = Data(base64Encoded: b64), data.count >= 3 {
              self.isCameraStreaming = data[data.startIndex + 2] == 1
            }
          }
          self.server?.notifySubscribers(aid: aid, iid: iid, value: value)
        }
      }

      // Discover available cameras; restore previous selections
      let cameras = CameraOption.availableCameras()
      self.availableCameras = cameras
      if self.selectedCamera == nil {
        let savedID = UserDefaults.standard.string(forKey: "selectedCameraID")
        self.selectedCamera =
          cameras.first(where: { $0.id == savedID })
          ?? cameras.first { $0.name.localizedCaseInsensitiveContains("front") }
          ?? cameras.first
      }
      if self.selectedStreamCamera == nil {
        let savedID = UserDefaults.standard.string(forKey: "selectedStreamCameraID")
        self.selectedStreamCamera =
          cameras.first(where: { $0.id == savedID })
          ?? cameras.first { $0.name.localizedCaseInsensitiveContains("back") }
          ?? cameras.first
      }
      self.cameraAccessory = camera
      camera.selectedCameraID = self.selectedStreamCamera?.id
      if let savedQuality = UserDefaults.standard.string(forKey: "videoQuality"),
        let quality = VideoQuality(rawValue: savedQuality)
      {
        self.videoQuality = quality
      }
      camera.minimumBitrate = self.videoQuality.minimumBitrate

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

      // Set up motion monitor (accelerometer)
      let motion = MotionMonitor()
      self.isMotionAvailable = motion.isAvailable
      motion.onMotionChange = { [weak motionSensor] detected in
        motionSensor?.updateMotionDetected(detected)
      }
      self.motionMonitor = motion

      pairingStore.onChange = { [weak self] in
        Task { @MainActor in
          self?.hasPairings = pairingStore.isPaired
        }
      }

      do {
        let hapServer = try HAPServer(
          bridge: bridge,
          accessories: [lightbulb, camera, lightSensor, motionSensor],
          pairingStore: pairingStore,
          deviceIdentity: identity
        )
        hapServer.start()
        self.server = hapServer
        self.hasPairings = pairingStore.isPaired
        self.isRunning = true
        self.isStarting = false
        self.statusMessage = "Advertising as '\(bridge.name)'\nDevice ID: \(identity.deviceID)"

        // Start ambient light monitoring with selected camera
        monitor.start(with: self.selectedCamera)

        // Start motion monitoring
        motion.start()

        // Prevent screen from sleeping
        UIApplication.shared.isIdleTimerDisabled = true
      } catch {
        self.isStarting = false
        self.statusMessage = "Failed to start: \(error.localizedDescription)"
      }
    }
  }

  @MainActor
  func stop() {
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

/// Build the `X-HM://` setup URI defined by the HAP spec.
/// The payload is a 45-bit integer, base-36 encoded and zero-padded to 9 chars:
///   bits  0–26: setup code as plain integer (digits without dashes)
///   bits 27–30: flags (2 = IP)
///   bits 31–38: accessory category
///   bits 39–44: reserved / version (0)
private func hapSetupURI(setupCode: String, category: Int = HAPAccessoryCategory.bridge.rawValue)
  -> String
{
  let digits = setupCode.filter(\.isWholeNumber)
  guard let code = UInt64(digits) else { return "" }
  let flags: UInt64 = 2  // IP accessory
  var payload: UInt64 = 0
  payload |= code
  payload |= flags << 27
  payload |= UInt64(category) << 31

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

// MARK: - Content View

struct ContentView: View {
  @ObservedObject var viewModel: HAPViewModel

  var body: some View {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          // Setup Code + QR
          if viewModel.isRunning {
            GroupBox("Setup Code") {
              VStack(spacing: 12) {
                if let qr = generateQRCode(from: hapSetupURI(setupCode: viewModel.setupCode)) {
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
            GroupBox("Light State") {
              VStack(spacing: 12) {
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
              }
              .frame(maxWidth: .infinity)
            }

            GroupBox("Ambient Light") {
              VStack(spacing: 8) {
                if viewModel.availableCameras.isEmpty {
                  Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                  Text("No cameras found")
                    .font(.headline)
                  Text("A camera is required for light sensing")
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else {
                  Image(systemName: "sun.max")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                  Text(String(format: "%.1f lux", viewModel.ambientLux))
                    .font(.system(.title2, design: .monospaced))

                  if viewModel.availableCameras.count > 1 {
                    Picker("Camera", selection: $viewModel.selectedCamera) {
                      ForEach(viewModel.availableCameras) { camera in
                        Text(camera.name).tag(Optional(camera))
                      }
                    }
                    .pickerStyle(.menu)
                  }

                  Text(viewModel.selectedCamera?.name ?? "Camera light estimate")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
              }
              .frame(maxWidth: .infinity)
            }

            GroupBox("Motion Sensor") {
              VStack(spacing: 8) {
                if viewModel.isMotionAvailable {
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
                } else {
                  Image(systemName: viewModel.isCameraStreaming ? "video.fill" : "video")
                    .font(.system(size: 32))
                    .foregroundColor(viewModel.isCameraStreaming ? .green : .gray)
                  Text(viewModel.isCameraStreaming ? "Streaming" : "Idle")
                    .font(.headline)

                  if viewModel.availableCameras.count > 1 {
                    Picker("Camera", selection: $viewModel.selectedStreamCamera) {
                      ForEach(viewModel.availableCameras) { camera in
                        Text(camera.name).tag(Optional(camera))
                      }
                    }
                    .pickerStyle(.menu)
                  }

                  Picker("Quality", selection: $viewModel.videoQuality) {
                    ForEach(VideoQuality.allCases) { quality in
                      Text(quality.rawValue).tag(quality)
                    }
                  }
                  .pickerStyle(.segmented)

                  Text(viewModel.selectedStreamCamera?.name ?? "Camera via HomeKit")
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
              .cornerRadius(10)
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
          .cornerRadius(12)
        }
        .disabled(viewModel.isStarting)
      }
      .padding()
    }
  }
}
