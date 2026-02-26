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

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "AmbientLight")
  private let lock = NSLock()

  private struct State {
    var captureSession: AVCaptureSession?
    var timer: Timer?
  }
  private var _state = State()

  private var captureSession: AVCaptureSession? {
    get { lock.withLock { _state.captureSession } }
    set { lock.withLock { _state.captureSession = newValue } }
  }

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

    let newTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      self?.sampleLux(from: camera, fNumber: fNumber)
    }
    lock.withLock {
      _state.captureSession = session
      _state.timer = newTimer
    }

    // Start on a background queue to avoid blocking the main thread
    DispatchQueue.global(qos: .background).async {
      session.startRunning()
    }

    logger.info("Ambient light monitor started (f/\(fNumber))")
  }

  func restart(with camera: CameraOption) {
    stop()
    start(with: camera)
  }

  /// Synchronously stop the capture session so the camera hardware is
  /// fully released before this method returns.  Used when another
  /// capture session needs exclusive camera access (e.g. snapshot).
  func pauseSession() {
    captureSession?.stopRunning()
    logger.debug("Ambient light session paused")
  }

  /// Restart a previously paused session.
  func resumeSession() {
    guard let session = captureSession, !session.isRunning else { return }
    DispatchQueue.global(qos: .background).async {
      session.startRunning()
    }
    logger.debug("Ambient light session resumed")
  }

  func stop() {
    let (oldTimer, oldSession): (Timer?, AVCaptureSession?) = lock.withLock {
      let t = _state.timer
      let s = _state.captureSession
      _state.timer = nil
      _state.captureSession = nil
      return (t, s)
    }
    oldTimer?.invalidate()
    oldSession?.stopRunning()

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
