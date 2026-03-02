@preconcurrency import AVFoundation
import AudioToolbox
@preconcurrency import CoreMedia
import FragmentedMP4
@preconcurrency import UIKit
import VideoToolbox
import os

/// Lightweight capture-only session for HKSV idle motion detection and fMP4 pre-buffering.
///
/// Runs whenever HKSV recording is armed but no live stream is active. Captures video,
/// runs motion detection, and encodes H.264 for the fMP4 pre-buffer — but performs no
/// RTP/SRTP/UDP/audio networking.
nonisolated final class MonitoringCaptureSession: @unchecked Sendable {

  /// Optional video motion detector — runs on every captured frame.
  var videoMotionDetector: VideoMotionDetector?

  /// Optional fMP4 writer for HKSV recording — feeds encoded H.264 samples.
  var fragmentWriter: FragmentedMP4Writer?

  /// Whether the hub has enabled audio recording (recordingAudioActive == 1).
  /// When false, microphone capture and AAC-ELD encoding are skipped entirely.
  var audioRecordingEnabled = false

  let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "MonitoringCapture")
  let lock = NSLock()

  /// Serial queue for AVCaptureSession start/stop — these are not thread-safe.
  private let sessionQueue: DispatchQueue
  private let sessionQueueKey = DispatchSpecificKey<Bool>()

  /// Serial queue for capture output delegate callbacks and encoding.
  private let captureQueue: DispatchQueue

  /// Serial queue for VT compression output handler.
  private let encodeQueue: DispatchQueue

  init() {
    let sQueue = DispatchQueue(label: "me.fausak.taylor.Pylo.monitorSession")
    sQueue.setSpecific(key: sessionQueueKey, value: true)
    self.sessionQueue = sQueue
    self.captureQueue = DispatchQueue(label: "me.fausak.taylor.Pylo.monitorCapture")
    self.encodeQueue = DispatchQueue(label: "me.fausak.taylor.Pylo.monitorEncode")
  }

  /// AAC-ELD frame size in samples (480 for 16kHz).
  let aacFrameSamples = 480

  struct State {
    var captureSession: AVCaptureSession?
    var compressionSession: VTCompressionSession?
    var encodeFrameCount: Int = 0
    var audioConverter: AudioConverterRef?
    var pcmAccumulator = Data()
  }
  var _state = State()

  // Strong references to delegates to prevent premature deallocation.
  private var videoCaptureDelegate: VideoCaptureDelegate?
  private var audioCaptureDelegate: AudioCaptureDelegate?

  private var captureSession: AVCaptureSession? {
    get { lock.withLock { _state.captureSession } }
    set { lock.withLock { _state.captureSession = newValue } }
  }

  private var compressionSession: VTCompressionSession? {
    get { lock.withLock { _state.compressionSession } }
    set { lock.withLock { _state.compressionSession = newValue } }
  }

  // MARK: - Lifecycle

  func start(camera: AVCaptureDevice) {
    // Atomically check-and-mark to prevent concurrent start().
    let alreadyRunning = lock.withLock { () -> Bool in
      if _state.captureSession != nil { return true }
      _state.captureSession = AVCaptureSession()  // sentinel
      return false
    }
    guard !alreadyRunning else { return }

    let width = 1920
    let height = 1080
    let fps = 30
    let bitrate = 2000  // kbps — match hub's SelectedCameraRecordingConfig

    // Configure camera frame rate
    do {
      try camera.lockForConfiguration()
      for range in camera.activeFormat.videoSupportedFrameRateRanges {
        if range.maxFrameRate >= Double(fps) {
          camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
          camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
          break
        }
      }
      camera.unlockForConfiguration()
    } catch {
      logger.error("Camera config error: \(error)")
      lock.withLock { _state.captureSession = nil }
      return
    }

    // Configure audio session BEFORE creating capture session so the mic is available
    #if os(iOS)
      do {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
          .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setPreferredSampleRate(16000)
        try audioSession.setActive(true)
      } catch {
        logger.error("AVAudioSession setup error: \(error)")
      }
    #endif

    let session = AVCaptureSession()
    session.sessionPreset = .hd1920x1080

    do {
      let input = try AVCaptureDeviceInput(device: camera)
      if session.canAddInput(input) { session.addInput(input) }
    } catch {
      logger.error("Camera input error: \(error)")
      lock.withLock { _state.captureSession = nil }
      return
    }

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    output.alwaysDiscardsLateVideoFrames = true
    let delegate = VideoCaptureDelegate { [weak self] pixelBuffer, pts in
      self?.videoMotionDetector?.processPixelBuffer(pixelBuffer)
      self?.encodeFrame(pixelBuffer, pts: pts)
    }
    output.setSampleBufferDelegate(delegate, queue: captureQueue)
    if session.canAddOutput(output) { session.addOutput(output) }

    // Add microphone input for audio capture (only when hub has enabled recording audio)
    var audioReady = false
    if audioRecordingEnabled, let mic = AVCaptureDevice.default(for: .audio),
      let micInput = try? AVCaptureDeviceInput(device: mic),
      session.canAddInput(micInput)
    {
      session.addInput(micInput)
      let audioOut = AVCaptureAudioDataOutput()
      let audioDelegate = AudioCaptureDelegate { [weak self] sampleBuffer in
        self?.handleAudioSampleBuffer(sampleBuffer)
      }
      audioOut.setSampleBufferDelegate(audioDelegate, queue: captureQueue)
      if session.canAddOutput(audioOut) {
        session.addOutput(audioOut)
        lock.withLock { self.audioCaptureDelegate = audioDelegate }

        // Create AAC-ELD encoder
        if let converter = Self.createAudioEncoder(logger: logger) {
          lock.withLock {
            _state.audioConverter = converter
            _state.pcmAccumulator = Data()
          }
          audioReady = true
          logger.info("Monitoring audio capture + AAC-ELD encoder ready")
        }
      }
    }
    if !audioReady {
      if !audioRecordingEnabled {
        logger.info("Monitoring capture: recording audio disabled by hub, video-only mode")
      } else {
        logger.info("Monitoring capture: microphone unavailable, video-only mode")
      }
    }

    // Rotate output to match device orientation.
    let rotationAngle = Self.currentRotationAngle()
    if let connection = output.connection(with: .video),
      connection.isVideoRotationAngleSupported(CGFloat(rotationAngle))
    {
      connection.videoRotationAngle = CGFloat(rotationAngle)
    }

    // Swap encoding dimensions when rotated 90°/270° — the capture connection
    // physically rotates pixel buffers, so the VT session must match.
    let swapDims = rotationAngle == 90 || rotationAngle == 270
    let encWidth = swapDims ? height : width
    let encHeight = swapDims ? width : height

    // VTCompressionSession setup
    guard
      let cs = Self.createCompressionSession(
        width: encWidth, height: encHeight, fps: fps, bitrate: bitrate, logger: logger)
    else {
      lock.withLock { _state.captureSession = nil }
      return
    }

    // Commit state atomically. If stop() was called concurrently, bail.
    let cancelled: Bool = lock.withLock {
      guard _state.captureSession != nil else { return true }
      _state.captureSession = session
      _state.compressionSession = cs
      _state.encodeFrameCount = 0
      return false
    }
    if cancelled {
      VTCompressionSessionInvalidate(cs)
      logger.info("Monitoring capture start aborted (stop() called concurrently)")
      return
    }
    lock.withLock {
      self.videoCaptureDelegate = delegate
    }
    fragmentWriter?.includeAudioTrack = audioReady

    sessionQueue.async {
      session.startRunning()
    }
    logger.info("Monitoring capture started (audio=\(audioReady))")
  }

  func stop() {
    let (oldSession, oldCS, oldAudioConverter):
      (AVCaptureSession?, VTCompressionSession?, AudioConverterRef?) = lock.withLock {
        let s = _state.captureSession
        let cs = _state.compressionSession
        let ac = _state.audioConverter
        _state.captureSession = nil
        _state.compressionSession = nil
        _state.encodeFrameCount = 0
        _state.audioConverter = nil
        _state.pcmAccumulator = Data()
        return (s, cs, ac)
      }
    guard oldSession != nil || oldCS != nil else { return }

    fragmentWriter?.includeAudioTrack = false

    // stopRunning() is synchronous — blocks until frames stop.
    let stopBlock = { oldSession?.stopRunning() }
    if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
      stopBlock()
    } else {
      sessionQueue.sync(execute: stopBlock)
    }

    // Drain in-flight captureQueue blocks.
    captureQueue.sync {}

    if let cs = oldCS {
      VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: .positiveInfinity)
      VTCompressionSessionInvalidate(cs)
      // Drain encode output handler blocks.
      encodeQueue.sync {}
    }

    if let ac = oldAudioConverter {
      AudioConverterDispose(ac)
    }

    lock.withLock {
      videoCaptureDelegate = nil
      audioCaptureDelegate = nil
    }
    logger.info("Monitoring capture stopped")
  }

  // MARK: - H.264 Encoding

  private func encodeFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    guard let cs = compressionSession else { return }

    let frameCount = lock.withLock {
      _state.encodeFrameCount += 1
      return _state.encodeFrameCount
    }

    // Force keyframe every 120 frames (4s at 30fps) to ensure predictable fragment
    // boundaries. Using only MaxKeyFrameInterval/Duration is insufficient because the
    // encoder's internal counter doesn't reset after an externally-forced keyframe.
    let props: CFDictionary? =
      frameCount % 120 == 1
      ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
      : nil

    var flags = VTEncodeInfoFlags()
    VTCompressionSessionEncodeFrame(
      cs,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: pts,
      duration: .invalid,
      frameProperties: props,
      infoFlagsOut: &flags,
      outputHandler: { [weak self] status, _, sampleBuffer in
        if status != noErr {
          self?.logger.error("Monitoring encode error: \(status)")
          return
        }
        guard let sampleBuffer else { return }
        self?.fragmentWriter?.appendVideoSample(sampleBuffer)
      }
    )
  }

  // MARK: - Helpers

  private static func createCompressionSession(
    width: Int, height: Int, fps: Int, bitrate: Int, logger: Logger
  ) -> VTCompressionSession? {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: nil,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: nil,
      refcon: nil,
      compressionSessionOut: &session
    )

    guard status == noErr, let cs = session else {
      logger.error("VTCompressionSession create failed: \(status)")
      return nil
    }

    VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_ProfileLevel,
      value: kVTProfileLevel_H264_Baseline_AutoLevel)
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_AverageBitRate,
      value: (bitrate * 1000) as CFNumber)
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
      value: (fps * 4) as CFNumber)  // 120 frames = 4s (match hub's I-frame interval)
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
      value: 4.0 as CFNumber)
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_ExpectedFrameRate,
      value: fps as CFNumber)
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_AllowFrameReordering,
      value: kCFBooleanFalse)
    let bytesPerSecond = (bitrate * 1000 / 8) as CFNumber
    let one = 1.0 as CFNumber
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_DataRateLimits,
      value: [bytesPerSecond, one] as CFArray)

    VTCompressionSessionPrepareToEncodeFrames(cs)
    return cs
  }

  private static func currentRotationAngle() -> Int {
    #if os(iOS)
      // Read cached orientation from OSAllocatedUnfairLock — safe from any thread.
      _ = orientationToken
      let orientation = UIDeviceOrientation(rawValue: orientationState.withLock { $0 }) ?? .portrait
      switch orientation {
      case .landscapeLeft: return 0
      case .landscapeRight: return 180
      case .portraitUpsideDown: return 270
      default: return 90
      }
    #else
      return 0
    #endif
  }

  /// Thread-safe device orientation cache — mirrors HAPCameraAccessory's DeviceOrientation pattern.
  private static let orientationState = OSAllocatedUnfairLock(
    initialState: Int(UIDeviceOrientation.portrait.rawValue)
  )
  private static let orientationToken: NSObjectProtocol =
    NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      let raw = MainActor.assumeIsolated { UIDevice.current.orientation.rawValue }
      orientationState.withLock { $0 = raw }
    }
}

// MARK: - Video Capture Delegate

/// Reusable delegate that forwards pixel buffers to a closure.
/// Defined here privately to avoid depending on CameraStreamSession's internal type.
private nonisolated final class VideoCaptureDelegate: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate
{
  let handler: (CVPixelBuffer, CMTime) -> Void

  init(handler: @escaping (CVPixelBuffer, CMTime) -> Void) {
    self.handler = handler
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    handler(pixelBuffer, pts)
  }
}

// MARK: - Audio Capture Delegate

private nonisolated final class AudioCaptureDelegate: NSObject,
  AVCaptureAudioDataOutputSampleBufferDelegate
{
  let handler: (CMSampleBuffer) -> Void

  init(handler: @escaping (CMSampleBuffer) -> Void) {
    self.handler = handler
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    handler(sampleBuffer)
  }
}
