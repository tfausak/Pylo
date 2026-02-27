@preconcurrency import AVFoundation
import os

/// A camera that can be used for ambient light sensing.
struct CameraOption: Identifiable, Hashable, Sendable {
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
nonisolated final class AmbientLightMonitor: @unchecked Sendable {

  var onLuxUpdate: ((Float) -> Void)?

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "AmbientLight")
  private let lock = NSLock()
  private let timerQueue: DispatchQueue
  private let timerQueueKey = DispatchSpecificKey<Bool>()
  /// Serial queue for AVCaptureSession start/stop — these are not thread-safe.
  private let sessionQueue: DispatchQueue
  private let sessionQueueKey = DispatchSpecificKey<Bool>()

  init() {
    let tQueue = DispatchQueue(label: "me.fausak.taylor.Pylo.lightTimer")
    tQueue.setSpecific(key: timerQueueKey, value: true)
    self.timerQueue = tQueue

    let queue = DispatchQueue(label: "me.fausak.taylor.Pylo.lightSession")
    queue.setSpecific(key: sessionQueueKey, value: true)
    self.sessionQueue = queue
  }

  private struct State {
    var captureSession: AVCaptureSession?
    var timer: DispatchSourceTimer?
  }
  private var _state = State()

  private var captureSession: AVCaptureSession? {
    get { lock.withLock { _state.captureSession } }
    set { lock.withLock { _state.captureSession = newValue } }
  }

  // Calibration constant (incident-light meter constant)
  private let calibrationConstant: Float = 12.5

  func start(with camera: CameraOption? = nil) {
    // Atomically check-and-mark to prevent concurrent start() from creating
    // two capture sessions (TOCTOU race on captureSession == nil).
    let alreadyRunning = lock.withLock { () -> Bool in
      if _state.captureSession != nil { return true }
      // Set a sentinel so a racing second call sees non-nil immediately.
      _state.captureSession = AVCaptureSession()
      return false
    }
    guard !alreadyRunning else { return }

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
      lock.withLock { _state.captureSession = nil }
      return
    }

    do {
      try camera.lockForConfiguration()
      camera.exposureMode = .continuousAutoExposure
      camera.unlockForConfiguration()
    } catch {
      logger.error("Failed to configure camera: \(error)")
      lock.withLock { _state.captureSession = nil }
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
      lock.withLock { _state.captureSession = nil }
      return
    }

    // A session needs at least one output to actually run the camera pipeline
    // (otherwise ISO/exposureDuration never update).
    let output = AVCaptureVideoDataOutput()
    guard session.canAddOutput(output) else {
      logger.error("Cannot add video output to ambient light session")
      lock.withLock { _state.captureSession = nil }
      return
    }
    session.addOutput(output)

    let newTimer = DispatchSource.makeTimerSource(queue: timerQueue)
    newTimer.schedule(deadline: .now() + 2.0, repeating: 2.0)
    newTimer.setEventHandler { [weak self] in
      self?.sampleLux(from: camera, fNumber: fNumber)
    }
    // Replace the sentinel with the real session.
    // If stop() was called between the sentinel set and now,
    // captureSession will be nil — abort to avoid orphaning a session.
    let cancelled: Bool = lock.withLock {
      guard _state.captureSession != nil else { return true }
      _state.captureSession = session
      _state.timer = newTimer
      return false
    }
    if cancelled {
      logger.info("Ambient light monitor start aborted (stop() called concurrently)")
      return
    }
    newTimer.resume()

    // Start on the session queue to avoid blocking the main thread
    sessionQueue.async {
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
    let pause = { [self] in captureSession?.stopRunning() }
    if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
      pause()
    } else {
      sessionQueue.sync(execute: pause)
    }
    logger.debug("Ambient light session paused")
  }

  /// Restart a previously paused session.
  func resumeSession() {
    guard let session = captureSession, !session.isRunning else { return }
    sessionQueue.async {
      session.startRunning()
    }
    logger.debug("Ambient light session resumed")
  }

  func stop() {
    let (oldTimer, oldSession): (DispatchSourceTimer?, AVCaptureSession?) = lock.withLock {
      let t = _state.timer
      let s = _state.captureSession
      _state.timer = nil
      _state.captureSession = nil
      return (t, s)
    }
    oldTimer?.cancel()
    // Drain timerQueue so any in-flight event handler finishes before we
    // stop the session — prevents reading device properties during teardown.
    if DispatchQueue.getSpecific(key: timerQueueKey) == nil {
      timerQueue.sync {}
    }
    // stopRunning() must execute on sessionQueue but we must avoid sync-on-self
    // deadlocks if the caller is already on sessionQueue.
    let stopBlock = { oldSession?.stopRunning() }
    if DispatchQueue.getSpecific(key: self.sessionQueueKey) != nil {
      stopBlock()
    } else {
      sessionQueue.sync(execute: stopBlock)
    }

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
