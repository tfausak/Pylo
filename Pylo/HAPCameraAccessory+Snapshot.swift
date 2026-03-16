@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Locked
import Streaming
import os

// MARK: - Snapshot

extension HAPCameraAccessory {

  /// Capture a single JPEG frame from the selected camera synchronously.
  /// Uses AVCaptureVideoDataOutput instead of AVCapturePhotoOutput to avoid
  /// the system shutter sound. Falls back to a cached frame from the last
  /// active stream when a fresh capture isn't possible.
  func captureSnapshot(width: Int, height: Int) -> Data? {
    // This method blocks synchronously for up to 3 seconds while waiting for
    // a camera frame. AVCaptureSession.startRunning() posts internal
    // notifications on the main thread, so calling this from the main thread
    // (or any context the main thread is blocked on) would deadlock.
    dispatchPrecondition(condition: .notOnQueue(.main))

    // If streaming is active, return the cached frame (can't run two sessions
    // on the same camera simultaneously). Use the lock-based accessor to avoid
    // a TOCTOU race with concurrent streamSession mutations.
    if hasActiveStreamSession {
      logger.info("Stream active -- returning cached snapshot")
      return cachedSnapshot
    }

    // If the monitoring session is caching snapshots, return the latest one
    // immediately. This avoids the 1-3 second cold-start delay of creating a
    // new AVCaptureSession, which causes HomeKit to show "No Response".
    // Only use cache if fresh (within 2s) to avoid serving stale images.
    if let cached = cachedSnapshot(maxAgeSeconds: 2) {
      logger.info("Returning cached monitoring snapshot")
      return cached
    }

    guard let camera = resolveCamera() else {
      logger.error("No camera available for snapshot")
      return cachedSnapshot
    }

    // Pause other capture sessions (e.g. monitoring session) -- iOS only
    // allows one AVCaptureSession at a time per camera, and even sessions on
    // different cameras can interfere with each other.
    onSnapshotWillCapture?()
    defer { onSnapshotDidCapture?() }

    let session = AVCaptureSession()
    session.enableMultitaskingCameraIfSupported()
    session.sessionPreset = width > 1280 ? .hd1920x1080 : width > 640 ? .hd1280x720 : .medium

    guard let input = try? AVCaptureDeviceInput(device: camera),
      session.canAddInput(input)
    else { return cachedSnapshot }
    session.addInput(input)

    let videoOutput = AVCaptureVideoDataOutput()
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    guard session.canAddOutput(videoOutput) else { return cachedSnapshot }
    session.addOutput(videoOutput)

    // Rotate to match current device orientation
    let rotation = currentRotation()
    if let connection = videoOutput.connection(with: .video) {
      if #available(iOS 17.0, macOS 14.0, *) {
        if connection.isVideoRotationAngleSupported(CGFloat(rotation.angle)) {
          connection.videoRotationAngle = CGFloat(rotation.angle)
        }
      } else {
        let orientation = videoOrientation(from: rotation.angle)
        if connection.isVideoOrientationSupported {
          connection.videoOrientation = orientation
        }
      }
    }

    // Skip early frames so auto-exposure has time to converge; the very
    // first frames from a cold-started session are often black/dark.
    let grabber = FrameGrabber(framesToSkip: 10, context: snapshotCIContext)
    let queue = DispatchQueue(
      label: "\(Bundle.main.bundleIdentifier!).snapshot", qos: .userInteractive)
    videoOutput.setSampleBufferDelegate(grabber, queue: queue)

    session.startRunning()
    defer { session.stopRunning() }

    // Wait up to 3 seconds for a usable frame
    _ = grabber.waitForCapture(timeout: .now() + 3)

    guard let cgImage = grabber.capturedImage else {
      logger.warning("Frame grab timed out -- returning cached snapshot")
      return cachedSnapshot
    }

    let ciImage = CIImage(cgImage: cgImage)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let jpeg = snapshotCIContext.jpegRepresentation(
        of: ciImage, colorSpace: colorSpace, options: [:])
    else { return cachedSnapshot }

    cachedSnapshot = jpeg
    return jpeg
  }
}

// MARK: - Frame Grabber (for silent snapshots)

nonisolated final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let semaphore = DispatchSemaphore(value: 0)
  /// CGImage copied from the pixel buffer inside the delegate callback, so
  /// the backing CVPixelBuffer can be safely recycled by AVFoundation.
  /// Protected by a lock to prevent data races between the capture queue
  /// (writer) and the calling thread (reader after semaphore wait).
  private let lock = NSLock()
  private let context: CIContext
  private var _capturedImage: CGImage?
  private var _framesReceived = 0
  var capturedImage: CGImage? { lock.withLock { _capturedImage } }
  private let framesToSkip: Int

  init(framesToSkip: Int = 0, context: CIContext = CIContext()) {
    self.framesToSkip = framesToSkip
    self.context = context
  }

  /// Block until a usable frame is captured, or the timeout expires.
  func waitForCapture(timeout: DispatchTime) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let shouldProcess = lock.withLock { () -> Bool in
      guard _capturedImage == nil else { return false }
      _framesReceived += 1
      return _framesReceived > framesToSkip
    }
    guard shouldProcess else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    // Render to CGImage immediately while the pixel buffer is still valid --
    // CIImage(cvPixelBuffer:) only holds a lazy reference and the pool may
    // recycle the backing memory after this callback returns.
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    lock.withLock { _capturedImage = cgImage }
    semaphore.signal()
  }
}
