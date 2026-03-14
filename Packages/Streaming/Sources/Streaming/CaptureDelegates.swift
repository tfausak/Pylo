import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - Video Capture Delegate

/// Reusable delegate that forwards pixel buffers to a closure.
/// Used by both CameraStreamSession and MonitoringCaptureSession.
public nonisolated final class VideoCaptureDelegate: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate
{
  let handler: (CVPixelBuffer, CMTime) -> Void

  public init(handler: @escaping (CVPixelBuffer, CMTime) -> Void) {
    self.handler = handler
  }

  public func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    handler(pixelBuffer, pts)
  }
}

// MARK: - Audio Capture Delegate

/// Reusable delegate that forwards audio sample buffers to a closure.
/// Used by both CameraStreamSession and MonitoringCaptureSession.
public nonisolated final class AudioCaptureDelegate: NSObject,
  AVCaptureAudioDataOutputSampleBufferDelegate
{
  let handler: (CMSampleBuffer) -> Void

  public init(handler: @escaping (CMSampleBuffer) -> Void) {
    self.handler = handler
  }

  public func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    handler(sampleBuffer)
  }
}
