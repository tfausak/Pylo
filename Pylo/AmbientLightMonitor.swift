import AVFoundation
import os

/// A camera that can be used for ambient light sensing.
struct CameraOption: Identifiable, Hashable {
  let id: String  // AVCaptureDevice.uniqueID
  let name: String
  let fNumber: Float

  static func availableCameras() -> [CameraOption] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
      mediaType: .video,
      position: .unspecified
    )
    return discovery.devices.map { device in
      CameraOption(
        id: device.uniqueID,
        name: device.localizedName,
        fNumber: device.lensAperture
      )
    }
  }
}

/// Monitors ambient light using a camera's auto-exposure metadata.
/// Estimates lux from ISO and exposure duration: `lux = (K × f²) / (ISO × t)`
final class AmbientLightMonitor {

  var onLuxUpdate: ((Float) -> Void)?

  private let logger = Logger(subsystem: "com.example.hap", category: "AmbientLight")
  private var captureSession: AVCaptureSession?
  private var timer: Timer?
  private var activeDevice: AVCaptureDevice?

  // Calibration constant (incident-light meter constant)
  private let calibrationConstant: Float = 12.5

  func start(with camera: CameraOption? = nil) {
    guard captureSession == nil else { return }

    let device: AVCaptureDevice?
    let fNumber: Float

    if let camera, let selected = AVCaptureDevice(uniqueID: camera.id) {
      device = selected
      fNumber = camera.fNumber
    } else {
      device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
      fNumber = device?.lensAperture ?? 2.2
    }

    guard let camera = device else {
      logger.warning("No camera available")
      return
    }

    do {
      try camera.lockForConfiguration()
      camera.exposureMode = .continuousAutoExposure
      camera.unlockForConfiguration()
    } catch {
      logger.error("Failed to configure camera: \(error)")
      return
    }

    let session = AVCaptureSession()
    session.sessionPreset = .low

    do {
      let input = try AVCaptureDeviceInput(device: camera)
      if session.canAddInput(input) {
        session.addInput(input)
      }
    } catch {
      logger.error("Failed to create capture input: \(error)")
      return
    }

    // A session needs at least one output to actually run the camera pipeline
    // (otherwise ISO/exposureDuration never update).
    let output = AVCaptureVideoDataOutput()
    if session.canAddOutput(output) {
      session.addOutput(output)
    }

    captureSession = session
    activeDevice = camera

    // Start on a background queue to avoid blocking the main thread
    DispatchQueue.global(qos: .background).async {
      session.startRunning()
    }

    // Sample every 2 seconds on the main run loop
    timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      self?.sampleLux(from: camera, fNumber: fNumber)
    }

    logger.info("Ambient light monitor started (f/\(fNumber))")
  }

  func restart(with camera: CameraOption) {
    stop()
    start(with: camera)
  }

  func stop() {
    timer?.invalidate()
    timer = nil

    if let session = captureSession {
      DispatchQueue.global(qos: .background).async {
        session.stopRunning()
      }
    }
    captureSession = nil

    logger.info("Ambient light monitor stopped")
  }

  private func sampleLux(from device: AVCaptureDevice, fNumber: Float) {
    let iso = device.iso
    let duration = Float(CMTimeGetSeconds(device.exposureDuration))

    guard duration > 0, iso > 0 else { return }

    // lux = (K × f²) / (ISO × t)
    let lux = (calibrationConstant * fNumber * fNumber) / (iso * duration)

    // Clamp to HAP range
    let clamped = max(0.0001, min(100_000, lux))

    logger.debug(
      "Lux estimate: \(clamped, format: .fixed(precision: 1)) (ISO=\(iso), t=\(duration)s)")
    onLuxUpdate?(clamped)
  }
}
