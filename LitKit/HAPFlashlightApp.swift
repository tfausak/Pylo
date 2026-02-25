import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - App Entry Point
// This is the main SwiftUI app. Create a new Xcode project (iOS App, SwiftUI)
// and replace the generated ContentView / App with this.

@main
struct HAPFlashlightApp: App {
    @StateObject private var viewModel = HAPViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}

// MARK: - View Model

final class HAPViewModel: ObservableObject {

    @Published var isRunning = false
    @Published var isLightOn = false
    @Published var brightness: Int = 100
    @Published var isPaired = false
    @Published var statusMessage = "Tap Start to begin"
    @Published var setupCode = PairSetupHandler.setupCode
    @Published var ambientLux: Float = 1.0

    private var server: HAPServer?
    private var lightMonitor: AmbientLightMonitor?

    @MainActor
    func start() {
        let accessory = HAPAccessory(
            name: "iPhone Flashlight",
            model: "HAP-PoC",
            manufacturer: "DIY",
            serialNumber: UIDevice.current.identifierForVendor?.uuidString ?? "000000",
            firmwareRevision: "0.1.0"
        )

        let pairingStore = PairingStore()
        let identity = DeviceIdentity()

        // Wire up state change callbacks
        accessory.onStateChange = { [weak self] aid, iid, value in
            Task { @MainActor in
                guard let self else { return }
                if iid == 9, let on = value as? Bool {
                    self.isLightOn = on
                } else if iid == 10, let brightness = value as? Int {
                    self.brightness = brightness
                } else if iid == 12, let lux = value as? Float {
                    self.ambientLux = lux
                }
                self.server?.notifySubscribers(aid: aid, iid: iid, value: value)
            }
        }

        // Set up ambient light monitor (front camera)
        let monitor = AmbientLightMonitor()
        monitor.onLuxUpdate = { [weak accessory] lux in
            accessory?.updateAmbientLight(lux)
        }
        self.lightMonitor = monitor

        do {
            let hapServer = try HAPServer(
                accessory: accessory,
                pairingStore: pairingStore,
                deviceIdentity: identity
            )
            hapServer.start()
            self.server = hapServer
            self.isRunning = true
            self.statusMessage = "Advertising as '\(accessory.name)'\nDevice ID: \(identity.deviceID)"

            // Start ambient light monitoring
            monitor.start()

            // Prevent screen from sleeping
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
        }
    }

    @MainActor
    func stop() {
        lightMonitor?.stop()
        lightMonitor = nil
        server?.stop()
        server = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        statusMessage = "Stopped"
    }
}

// MARK: - HomeKit QR Code Helpers

/// Build the `X-HM://` setup URI defined by the HAP spec.
/// The payload is a 45-bit integer, base-36 encoded and zero-padded to 9 chars:
///   bits  0–26: setup code as plain integer (digits without dashes)
///   bits 27–30: flags (2 = IP)
///   bits 31–38: accessory category
///   bits 39–44: reserved / version (0)
private func hapSetupURI(setupCode: String, category: Int = HAPAccessoryCategory.lightbulb.rawValue) -> String {
    let digits = setupCode.filter(\.isWholeNumber)
    guard let code = UInt64(digits) else { return "" }
    let flags: UInt64 = 2 // IP accessory
    var payload: UInt64 = 0
    payload |= code
    payload |= flags << 27
    payload |= UInt64(category) << 31

    // Base-36 encode, uppercase, zero-padded to 9 characters
    var encoded = String(payload, radix: 36, uppercase: true)
    while encoded.count < 9 { encoded = "0" + encoded }
    return "X-HM://\(encoded)"
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
        VStack(spacing: 24) {
            Text("HAP Flashlight")
                .font(.largeTitle)
                .fontWeight(.bold)

            // Status
            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(viewModel.isRunning ? .green : .gray)
                            .frame(width: 12, height: 12)
                        Text(viewModel.isRunning ? "Running" : "Stopped")
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
                        Image(systemName: "sun.max")
                            .font(.system(size: 32))
                            .foregroundColor(.orange)
                        Text(String(format: "%.1f lux", viewModel.ambientLux))
                            .font(.system(.title2, design: .monospaced))
                        Text("Front camera light estimate")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Spacer()

            // Start/Stop Button
            Button(action: {
                if viewModel.isRunning {
                    viewModel.stop()
                } else {
                    viewModel.start()
                }
            }) {
                Text(viewModel.isRunning ? "Stop Server" : "Start Server")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(viewModel.isRunning ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding()
    }
}
