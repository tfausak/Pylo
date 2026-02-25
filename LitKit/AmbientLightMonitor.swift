import AVFoundation
import os

/// Monitors ambient light using the front camera's auto-exposure metadata.
/// Estimates lux from ISO and exposure duration: `lux = (K × f²) / (ISO × t)`
final class AmbientLightMonitor {

    var onLuxUpdate: ((Float) -> Void)?

    private let logger = Logger(subsystem: "com.example.hap", category: "AmbientLight")
    private var captureSession: AVCaptureSession?
    private var timer: Timer?

    // Front camera approximate f-number
    private let fNumber: Float = 2.2
    // Calibration constant (incident-light meter constant)
    private let K: Float = 12.5

    func start() {
        guard captureSession == nil else { return }

        guard let frontCamera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) else {
            logger.warning("No front camera available")
            return
        }

        do {
            try frontCamera.lockForConfiguration()
            frontCamera.exposureMode = .continuousAutoExposure
            frontCamera.unlockForConfiguration()
        } catch {
            logger.error("Failed to configure front camera: \(error)")
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .low

        do {
            let input = try AVCaptureDeviceInput(device: frontCamera)
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

        // Start on a background queue to avoid blocking the main thread
        DispatchQueue.global(qos: .background).async {
            session.startRunning()
        }

        // Sample every 2 seconds on the main run loop
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sampleLux(from: frontCamera)
        }

        logger.info("Ambient light monitor started")
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

    private func sampleLux(from device: AVCaptureDevice) {
        let iso = device.iso
        let duration = Float(CMTimeGetSeconds(device.exposureDuration))

        guard duration > 0, iso > 0 else { return }

        // lux = (K × f²) / (ISO × t)
        let lux = (K * fNumber * fNumber) / (iso * duration)

        // Clamp to HAP range
        let clamped = max(0.0001, min(100_000, lux))

        logger.debug("Lux estimate: \(clamped, format: .fixed(precision: 1)) (ISO=\(iso), t=\(duration)s)")
        onLuxUpdate?(clamped)
    }
}
