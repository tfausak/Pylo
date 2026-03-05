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

  /// Optional video motion detector — called every `motionFrameInterval` frames.
  /// Protected: written from server queue, read from captureQueue.
  private let _videoMotionDetector = OSAllocatedUnfairLock<VideoMotionDetector?>(initialState: nil)
  var videoMotionDetector: VideoMotionDetector? {
    get { _videoMotionDetector.withLock { $0 } }
    set { _videoMotionDetector.withLock { $0 = newValue } }
  }

  /// Optional ambient light detector — called every `luxFrameInterval` frames.
  /// Protected: written from server queue, read from captureQueue.
  private let _ambientLightDetector = OSAllocatedUnfairLock<AmbientLightDetector?>(
    initialState: nil)
  var ambientLightDetector: AmbientLightDetector? {
    get { _ambientLightDetector.withLock { $0 } }
    set { _ambientLightDetector.withLock { $0 = newValue } }
  }

  /// Optional fMP4 writer for HKSV recording — feeds encoded H.264 samples.
  /// Protected: written from server queue, read from VT output handler and start/stop.
  private let _fragmentWriter = OSAllocatedUnfairLock<FragmentedMP4Writer?>(initialState: nil)
  var fragmentWriter: FragmentedMP4Writer? {
    get { _fragmentWriter.withLock { $0 } }
    set { _fragmentWriter.withLock { $0 = newValue } }
  }

  /// Whether the hub has enabled audio recording (recordingAudioActive == 1).
  /// When false, microphone capture and AAC-ELD encoding are skipped entirely.
  /// Protected: written from server queue, read from start().
  private let _audioRecordingEnabled = OSAllocatedUnfairLock(initialState: false)
  var audioRecordingEnabled: Bool {
    get { _audioRecordingEnabled.withLock { $0 } }
    set { _audioRecordingEnabled.withLock { $0 = newValue } }
  }

  let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MonitoringCapture")

  /// Serial queue for AVCaptureSession start/stop — these are not thread-safe.
  private let sessionQueue: DispatchQueue
  private let sessionQueueKey = DispatchSpecificKey<Bool>()

  /// Serial queue for capture output delegate callbacks and encoding.
  private let captureQueue: DispatchQueue

  /// Keyframe interval counter — only accessed on captureQueue, no lock needed.
  /// Reset in start()/stop() before captureQueue delivers frames.
  private var encodeFrameCount: Int = 0

  /// Frame counter for throttling motion/lux/snapshot detection — captureQueue only.
  /// Motion fires every 15 frames (~2fps at 30fps), lux every 60 (~0.5fps),
  /// snapshot every 30 (~1fps).
  private var captureFrameCount: Int = 0
  private let motionFrameInterval = 15
  private let luxFrameInterval = 60
  private let snapshotFrameInterval = 30

  /// Callback to periodically provide a pixel buffer for snapshot caching.
  /// Called every ~1 second on the captureQueue. The receiver should JPEG-encode
  /// the buffer and cache it for fast snapshot responses.
  /// Protected: written from server queue, read from captureQueue.
  private let _snapshotCallback = OSAllocatedUnfairLock<((CVPixelBuffer) -> Void)?>(
    initialState: nil)
  var snapshotCallback: ((CVPixelBuffer) -> Void)? {
    get { _snapshotCallback.withLock { $0 } }
    set { _snapshotCallback.withLock { $0 = newValue } }
  }

  init() {
    let sQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).monitorSession")
    sQueue.setSpecific(key: sessionQueueKey, value: true)
    self.sessionQueue = sQueue
    self.captureQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).monitorCapture")
  }

  /// AAC-ELD frame size in samples (480 for 16kHz).
  let aacFrameSamples = 480

  // @unchecked Sendable because VTCompressionSession and AudioConverterRef are
  // non-Sendable CFTypeRefs. Accesses to these fields use withLockUnchecked
  // (to bypass the Sendable return-type check), while Sendable fields like
  // captureSession use the regular withLock.
  struct State: @unchecked Sendable {
    var captureSession: AVCaptureSession?
    var compressionSession: VTCompressionSession?  // non-Sendable → withLockUnchecked
    var audioConverter: AudioConverterRef?  // non-Sendable → withLockUnchecked
    var pcmAccumulator = Data()
    // Strong references to delegates to prevent premature deallocation.
    // Stored as AnyObject to avoid exposing file-private delegate types.
    var videoCaptureDelegate: VideoCaptureDelegate?
    var audioCaptureDelegate: AudioCaptureDelegate?
  }
  let mState = OSAllocatedUnfairLock(initialState: State())

  private var captureSession: AVCaptureSession? {
    get { mState.withLock { $0.captureSession } }
    set { mState.withLock { $0.captureSession = newValue } }
  }

  private var compressionSession: VTCompressionSession? {
    get { mState.withLockUnchecked { $0.compressionSession } }
    set { mState.withLockUnchecked { $0.compressionSession = newValue } }
  }

  // MARK: - Lifecycle

  func start(camera: AVCaptureDevice, existingSession: AVCaptureSession? = nil) {
    // Atomically check-and-mark to prevent concurrent start().
    let alreadyRunning = mState.withLock { (state: inout State) -> Bool in
      if state.captureSession != nil { return true }
      state.captureSession = existingSession ?? AVCaptureSession()  // sentinel (or reuse)
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
        if range.minFrameRate <= Double(fps) && range.maxFrameRate >= Double(fps) {
          camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
          camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
          break
        }
      }
      camera.unlockForConfiguration()
    } catch {
      logger.error("Camera config error: \(error)")
      mState.withLock { $0.captureSession = nil }
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
        // Non-fatal: continue in video-only mode. The sentinel captureSession
        // will be replaced with the real session below, or cleared by later
        // error paths if video setup also fails.
        logger.error("AVAudioSession setup error: \(error)")
      }
    #endif

    // Build the new video output and delegate (shared between both paths)
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    output.alwaysDiscardsLateVideoFrames = true
    let delegate = VideoCaptureDelegate { [weak self] pixelBuffer, pts in
      guard let self else { return }
      self.captureFrameCount += 1
      if self.captureFrameCount % self.motionFrameInterval == 0 {
        self.videoMotionDetector?.processPixelBuffer(pixelBuffer)
      }
      if self.captureFrameCount % self.luxFrameInterval == 0 {
        self.ambientLightDetector?.sample()
      }
      if self.captureFrameCount % self.snapshotFrameInterval == 0 {
        self.snapshotCallback?(pixelBuffer)
      }
      self.encodeFrame(pixelBuffer, pts: pts)
    }
    output.setSampleBufferDelegate(delegate, queue: captureQueue)

    let session: AVCaptureSession
    var audioReady = false

    if let existing = existingSession {
      // Reuse the stream session's running AVCaptureSession — reconfigure
      // in-place to avoid the ~500ms cold-start of creating a new one.
      session = existing
      logger.info("Reusing handed-off capture session for monitoring")

      session.beginConfiguration()

      // Remove stream's outputs
      for old in session.outputs { session.removeOutput(old) }

      // Restore preset to monitoring's 1080p
      if session.sessionPreset != .hd1920x1080 { session.sessionPreset = .hd1920x1080 }

      // Add monitoring video output
      if session.canAddOutput(output) {
        session.addOutput(output)
      } else {
        logger.error("Failed to add monitoring video output to reused capture session")
        session.commitConfiguration()
        mState.withLock { $0.captureSession = nil }
        return
      }

      // Add audio if needed and not already present
      if audioRecordingEnabled {
        let hasMic = session.inputs.contains { input in
          (input as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true
        }
        if !hasMic, let mic = AVCaptureDevice.default(for: .audio),
          let micInput = try? AVCaptureDeviceInput(device: mic),
          session.canAddInput(micInput)
        {
          session.addInput(micInput)
        }

        let audioOut = AVCaptureAudioDataOutput()
        let audioDelegate = AudioCaptureDelegate { [weak self] sampleBuffer in
          self?.handleAudioSampleBuffer(sampleBuffer)
        }
        audioOut.setSampleBufferDelegate(audioDelegate, queue: captureQueue)
        if session.canAddOutput(audioOut) {
          session.addOutput(audioOut)
          mState.withLock { $0.audioCaptureDelegate = audioDelegate }
          if let converter = createAACELDEncoder() {
            mState.withLockUnchecked {
              $0.audioConverter = converter
              $0.pcmAccumulator = Data()
            }
            audioReady = true
          }
        }
      }

      // Remove mic input if monitoring doesn't need audio but stream had it
      if !audioRecordingEnabled {
        for input in session.inputs {
          if let devInput = input as? AVCaptureDeviceInput,
            devInput.device.hasMediaType(.audio)
          {
            session.removeInput(devInput)
          }
        }
      }

      session.commitConfiguration()
      // Session is already running — no startRunning() needed
    } else {
      // Cold start — create a new AVCaptureSession from scratch
      session = AVCaptureSession()
      session.sessionPreset = .hd1920x1080

      do {
        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) { session.addInput(input) }
      } catch {
        logger.error("Camera input error: \(error)")
        mState.withLock { $0.captureSession = nil }
        return
      }

      if session.canAddOutput(output) {
        session.addOutput(output)
      } else {
        logger.error("Unable to add video output to monitoring capture session; aborting cold start")
        mState.withLock { $0.captureSession = nil }
        return
      }

      // Add microphone input for audio capture (only when hub has enabled recording audio)
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
          mState.withLock { $0.audioCaptureDelegate = audioDelegate }

          // Create AAC-ELD encoder
          if let converter = createAACELDEncoder() {
            mState.withLockUnchecked {
              $0.audioConverter = converter
              $0.pcmAccumulator = Data()
            }
            audioReady = true
            logger.info("Monitoring audio capture + AAC-ELD encoder ready")
          }
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
      mState.withLock { $0.captureSession = nil }
      return
    }

    // Commit state atomically. If stop() was called concurrently, bail.
    let cancelled: Bool = mState.withLockUnchecked { (state: inout State) -> Bool in
      guard state.captureSession != nil else { return true }
      state.captureSession = session
      state.compressionSession = cs
      return false
    }
    if cancelled {
      VTCompressionSessionInvalidate(cs)
      logger.info("Monitoring capture start aborted (stop() called concurrently)")
      return
    }
    mState.withLock {
      $0.videoCaptureDelegate = delegate
    }
    fragmentWriter?.includeAudioTrack = audioReady

    // Reset frame counters on captureQueue synchronously before starting the
    // session to guarantee they are zeroed before the first frame arrives.
    // Using async here would race with sessionQueue.async { startRunning() }
    // since the two queues have no ordering guarantee.
    captureQueue.sync { [self] in
      encodeFrameCount = 0
      captureFrameCount = 0
    }
    if existingSession == nil {
      sessionQueue.sync {
        session.startRunning()
      }
    }
    logger.info(
      "Monitoring capture started (audio=\(audioReady), reused=\(existingSession != nil))")
  }

  func stop() {
    let (oldSession, oldCS, oldAudioConverter):
      (AVCaptureSession?, VTCompressionSession?, AudioConverterRef?) = mState.withLockUnchecked {
        let s = $0.captureSession
        let cs = $0.compressionSession
        let ac = $0.audioConverter
        $0.captureSession = nil
        $0.compressionSession = nil
        $0.audioConverter = nil
        $0.pcmAccumulator = Data()
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
    }

    if let ac = oldAudioConverter {
      AudioConverterDispose(ac)
    }

    mState.withLock {
      $0.videoCaptureDelegate = nil
      $0.audioCaptureDelegate = nil
    }
    logger.info("Monitoring capture stopped")
  }

  /// Hand off the running AVCaptureSession to a stream session for reuse.
  /// Cleans up monitoring-specific resources (compression, audio encoder, delegates)
  /// but does NOT stop the capture session — the caller takes ownership.
  /// Returns nil if no session is running.
  func handoff() -> AVCaptureSession? {
    let (session, oldCS, oldAudioConverter):
      (AVCaptureSession?, VTCompressionSession?, AudioConverterRef?) = mState.withLockUnchecked {
        let s = $0.captureSession
        let cs = $0.compressionSession
        let ac = $0.audioConverter
        $0.captureSession = nil
        $0.compressionSession = nil
        $0.audioConverter = nil
        $0.pcmAccumulator = Data()
        return (s, cs, ac)
      }
    guard let session else { return nil }

    fragmentWriter?.includeAudioTrack = false

    // Remove our outputs so AVFoundation stops delivering frames to our
    // delegates before we release them. Without this, in-flight frames can
    // be delivered to a deallocated delegate.
    session.beginConfiguration()
    for old in session.outputs { session.removeOutput(old) }
    session.commitConfiguration()

    // Drain in-flight captureQueue blocks before invalidating the compression
    // session. An encodeFrame() call may have already read compressionSession
    // (non-nil) before the lock cleared it — invalidating while it's mid-encode
    // causes kVTInvalidSessionErr (-12903).
    dispatchPrecondition(condition: .notOnQueue(captureQueue))
    captureQueue.sync {}

    if let cs = oldCS {
      VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: .positiveInfinity)
      VTCompressionSessionInvalidate(cs)
    }

    if let ac = oldAudioConverter {
      AudioConverterDispose(ac)
    }

    mState.withLock {
      $0.videoCaptureDelegate = nil
      $0.audioCaptureDelegate = nil
    }
    logger.info("Monitoring capture handed off (session still running)")
    return session
  }

  // MARK: - H.264 Encoding

  private func encodeFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    guard let cs = compressionSession else { return }

    encodeFrameCount += 1
    let frameCount = encodeFrameCount

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
        // Wrap in autoreleasepool: VT calls this handler on an unspecified
        // thread that may not drain its autorelease pool. CF→Swift bridging
        // inside appendVideoSample creates autoreleased objects that would
        // otherwise accumulate at 30fps.
        autoreleasepool {
          if status != noErr {
            self?.logger.error("Monitoring encode error: \(status)")
            return
          }
          guard let sampleBuffer else { return }
          self?.fragmentWriter?.appendVideoSample(sampleBuffer)
        }
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
      // Use the shared orientation cache (DeviceOrientationCache) to avoid
      // duplicate notification observers.
      switch DeviceOrientationCache.current {
      case .landscapeLeft: return 0
      case .landscapeRight: return 180
      case .portraitUpsideDown: return 270
      default: return 90
      }
    #else
      return 0
    #endif
  }
}
