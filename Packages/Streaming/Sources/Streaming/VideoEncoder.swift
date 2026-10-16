import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoEncodingFailure: Error, Equatable {
  case invalidConfiguration
  case videoToolbox(OSStatus)
}

/// A serially owned hardware encoder. Call encode/finish from one capture queue,
/// and drain that queue before releasing it. The output callback may run on a
/// VideoToolbox thread and receives an immutable, retained sample buffer.
/// This type intentionally isn't Sendable: ownership belongs to the capture
/// pipeline, not to independent callers on several queues.
@available(iOS 17.4, *)
public final class VideoEncoder {
  public typealias Failure = VideoEncodingFailure

  private final class Output {
    let callback: @Sendable (OSStatus, CMSampleBuffer?) -> Void
    init(_ callback: @escaping @Sendable (OSStatus, CMSampleBuffer?) -> Void) {
      self.callback = callback
    }
  }

  private let output: Output
  private let width: Int
  private let height: Int
  private var compression: VTCompressionSession?
  private var lastPTS: CMTime = .invalid
  private var nextKeyframe: CMTime = .invalid

  public init(
    portrait: Bool = false,
    output: @escaping @Sendable (OSStatus, CMSampleBuffer?) -> Void
  ) throws {
    width = portrait ? 2160 : 3840
    height = portrait ? 3840 : 2160
    self.output = Output(output)
    let box = self.output
    let status = VTCompressionSessionCreate(
      allocator: nil, width: Int32(width), height: Int32(height),
      codecType: kCMVideoCodecType_HEVC,
      encoderSpecification: [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
      ] as CFDictionary,
      imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: { pointer, _, status, _, sample in
        guard let pointer else { return }
        Unmanaged<Output>.fromOpaque(pointer).takeUnretainedValue().callback(status, sample)
      },
      refcon: Unmanaged.passUnretained(box).toOpaque(), compressionSessionOut: &compression)
    guard status == noErr, let compression else { throw Failure.videoToolbox(status) }
    // Each property is required. Don't silently advertise an encoder which
    // ignored its bitrate, profile, or frame-reordering constraint.
    try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    try set(
      kVTCompressionPropertyKey_ProfileLevel,
      kVTProfileLevel_HEVC_Main_AutoLevel)
    try set(
      kVTCompressionPropertyKey_AverageBitRate, 5_000_000 as CFNumber)
    try set(
      kVTCompressionPropertyKey_DataRateLimits,
      [625_000 as CFNumber, 1 as CFNumber] as CFArray)
    try set(kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber)
    try set(
      kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
      4 as CFNumber)
    try set(
      kVTCompressionPropertyKey_MaxKeyFrameInterval,
      120 as CFNumber)
    let prepared = VTCompressionSessionPrepareToEncodeFrames(compression)
    guard prepared == noErr else { throw Failure.videoToolbox(prepared) }
  }

  deinit {
    if let compression {
      // Keep the output box alive until every in-flight callback has drained.
      VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .positiveInfinity)
      VTCompressionSessionInvalidate(compression)
    }
  }

  private func set(_ key: CFString, _ value: CFTypeRef) throws {
    guard let compression else { throw Failure.invalidConfiguration }
    let status = VTSessionSetProperty(compression, key: key, value: value)
    guard status == noErr else { throw Failure.videoToolbox(status) }
  }

  /// Accept only native 4K frames in the capture orientation; never upscale.
  public func encode(_ pixels: CVPixelBuffer, pts: CMTime) throws {
    guard let compression, pts.isNumeric,
      CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height
    else { throw Failure.invalidConfiguration }
    if lastPTS.isValid {
      let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, lastPTS))
      guard elapsed >= 0 else { throw Failure.invalidConfiguration }
      if elapsed < 1.0 / 30 - 0.0001 { return }
    }
    let keyframe = !nextKeyframe.isValid || CMTimeCompare(pts, nextKeyframe) >= 0
    let status = VTCompressionSessionEncodeFrame(
      compression, imageBuffer: pixels, presentationTimeStamp: pts,
      duration: CMTime(value: 1, timescale: 30),
      frameProperties: keyframe
        ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
      sourceFrameRefcon: nil, infoFlagsOut: nil)
    guard status == noErr else { throw Failure.videoToolbox(status) }
    lastPTS = pts
    if keyframe {
      nextKeyframe = CMTimeAdd(
        pts, CMTime(seconds: 4, preferredTimescale: 90_000))
    }
  }

  /// Drain pending callbacks before the owner disposes its output consumer.
  public func finish() throws {
    guard let compression else { return }
    let status = VTCompressionSessionCompleteFrames(
      compression, untilPresentationTimeStamp: .positiveInfinity)
    guard status == noErr else { throw Failure.videoToolbox(status) }
  }
}
