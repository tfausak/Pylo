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

    // If streaming is active, encode the cached frame on demand.
    if hasActiveStreamSession {
      if let frame = cachedFrame {
        logger.debug("Stream active -- encoding cached frame (\(frame.width)x\(frame.height))")
        return jpegEncode(frame)
      }
      logger.debug("Stream active -- no cached frame available")
      return nil
    }

    // If a cached frame exists, JPEG-encode it on demand. This avoids the
    // 1-3 second cold-start delay of creating a new AVCaptureSession (which
    // causes "No Response") AND avoids the monitoring session stop/restart
    // cycle that produces black frames while auto-exposure reconverges.
    // A stale frame is always preferable to a black one or "No Response".
    if let frame = cachedFrame {
      logger.debug("Encoding cached frame on demand (\(frame.width)x\(frame.height))")
      let jpeg = jpegEncode(frame)
      logger.debug("JPEG result: \(jpeg?.count ?? 0) bytes")
      return jpeg
    }

    guard let camera = resolveCamera() else {
      logger.error("No camera available for snapshot")
      return nil
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
    else { return nil }
    session.addInput(input)

    let videoOutput = AVCaptureVideoDataOutput()
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    guard session.canAddOutput(videoOutput) else { return nil }
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
      logger.warning("Frame grab timed out")
      return nil
    }

    cachedFrame = cgImage
    return jpegEncode(cgImage)
  }
}

// MARK: - Frame Grabber (for silent snapshots)

nonisolated final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Pylo", category: "FrameGrabber")
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

  /// Quick check whether a CGImage is all-black (or near-black).  Samples a
  /// few spread-out pixels via a tiny 4×1 CGContext render — cheap enough to
  /// run on the capture callback queue.
  private static func isBlackFrame(_ image: CGImage) -> Bool {
    let w = image.width
    let h = image.height
    guard w > 0, h > 0 else { return true }
    // Draw 4 sampled source pixels into a 4×1 strip
    let samplePoints: [(Int, Int)] = [
      (w / 4, h / 4), (3 * w / 4, h / 4),
      (w / 2, h / 2), (w / 4, 3 * h / 4),
    ]
    guard
      let ctx = CGContext(
        data: nil, width: 4, height: 1,
        bitsPerComponent: 8, bytesPerRow: 4 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
          | CGImageAlphaInfo.noneSkipFirst.rawValue)
    else { return false }
    for (i, (sx, sy)) in samplePoints.enumerated() {
      // Crop a 1×1 rect from the source and draw it into position i
      if let cropped = image.cropping(to: CGRect(x: sx, y: sy, width: 1, height: 1)) {
        ctx.draw(cropped, in: CGRect(x: i, y: 0, width: 1, height: 1))
      }
    }
    guard let data = ctx.data else { return false }
    for i in 0..<4 {
      // byteOrder32Little | noneSkipFirst → memory layout: B G R X
      let offset = i * 4
      let b = data.load(fromByteOffset: offset, as: UInt8.self)
      let g = data.load(fromByteOffset: offset + 1, as: UInt8.self)
      let r = data.load(fromByteOffset: offset + 2, as: UInt8.self)
      if r > 8 || g > 8 || b > 8 { return false }
    }
    return true
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
    // Reject all-black frames (auto-exposure hasn't converged yet) — keep trying.
    if Self.isBlackFrame(cgImage) {
      Self.logger.debug("Rejected black frame (frame \(self._framesReceived))")
      return
    }
    lock.withLock { _capturedImage = cgImage }
    semaphore.signal()
  }
}
