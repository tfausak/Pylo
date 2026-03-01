@preconcurrency import AVFoundation
import AudioToolbox
@preconcurrency import CoreMedia
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

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "MonitoringCapture")
  private let lock = NSLock()

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
  private let aacFrameSamples = 480

  private struct State {
    var captureSession: AVCaptureSession?
    var compressionSession: VTCompressionSession?
    var encodeFrameCount: Int = 0
    var audioConverter: AudioConverterRef?
    var pcmAccumulator = Data()
  }
  private var _state = State()

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
        self.audioCaptureDelegate = audioDelegate

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

    // VTCompressionSession setup
    guard
      let cs = Self.createCompressionSession(
        width: width, height: height, fps: fps, bitrate: bitrate, logger: logger)
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
    self.videoCaptureDelegate = delegate
    fragmentWriter?.includeAudioTrack = audioReady

    sessionQueue.async {
      session.startRunning()
    }
    logger.info("Monitoring capture started (audio=\(audioReady))")
  }

  func stop() {
    let (oldSession, oldCS, oldAudioConverter): (AVCaptureSession?, VTCompressionSession?, AudioConverterRef?) = lock.withLock {
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

    videoCaptureDelegate = nil
    audioCaptureDelegate = nil
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

  // MARK: - Audio Encoding

  private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    let converter = lock.withLock { _state.audioConverter }
    guard converter != nil else { return }

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(
      blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard let ptr = dataPointer, totalLength > 0 else { return }

    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee

    let rawData = Data(bytes: ptr, count: totalLength)

    let pcmFloat32: Data
    if let asbd, asbd.mFormatID == kAudioFormatLinearPCM {
      pcmFloat32 = Self.convertToFloat32At16kHz(rawData, sourceASBD: asbd)
    } else {
      logger.warning("Audio: unexpected format ID \(asbd?.mFormatID ?? 0)")
      return
    }

    // Accumulate PCM and encode when we have enough for an AAC-ELD frame
    lock.withLock { _state.pcmAccumulator.append(pcmFloat32) }
    let frameSizeBytes = aacFrameSamples * 4  // 480 samples * 4 bytes/sample (Float32)

    while true {
      let frameData: Data? = lock.withLock {
        guard _state.pcmAccumulator.count >= frameSizeBytes else { return nil }
        let frame = Data(_state.pcmAccumulator.prefix(frameSizeBytes))
        _state.pcmAccumulator = Data(_state.pcmAccumulator.dropFirst(frameSizeBytes))
        return frame
      }
      guard let frameData else { break }
      encodeAndAppendAudioFrame(frameData)
    }
  }

  private func encodeAndAppendAudioFrame(_ pcmData: Data) {
    let converter = lock.withLock { _state.audioConverter }
    guard let converter else { return }

    var packetSize: UInt32 = 1
    let outputBufferSize: UInt32 = 1024
    let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(outputBufferSize))
    defer { outputBuffer.deallocate() }

    var outputBufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: outputBufferSize,
        mData: outputBuffer
      )
    )

    var outputPacketDesc = AudioStreamPacketDescription()

    let status: OSStatus = pcmData.withUnsafeBytes { pcmBuf -> OSStatus in
      guard let pcmBase = pcmBuf.baseAddress else { return -1 }

      var cbData = AudioEncoderInput(
        srcData: pcmBase,
        srcSize: UInt32(pcmData.count),
        consumed: false
      )

      return withUnsafeMutablePointer(to: &cbData) { cbPtr in
        AudioConverterFillComplexBuffer(
          converter,
          { (_, ioNumberDataPackets, ioData, _, inUserData) -> OSStatus in
            guard let userData = inUserData else {
              ioNumberDataPackets.pointee = 0
              return noErr
            }
            let cb = userData.assumingMemoryBound(to: AudioEncoderInput.self)

            if cb.pointee.consumed {
              ioNumberDataPackets.pointee = 0
              return noErr
            }
            cb.pointee.consumed = true

            ioNumberDataPackets.pointee = UInt32(cb.pointee.srcSize / 4)
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: cb.pointee.srcData)
            ioData.pointee.mBuffers.mDataByteSize = cb.pointee.srcSize
            ioData.pointee.mBuffers.mNumberChannels = 1
            return noErr
          },
          cbPtr,
          &packetSize,
          &outputBufferList,
          &outputPacketDesc
        )
      }
    }

    guard status == noErr else {
      logger.warning("AAC-ELD encode error: \(status)")
      return
    }

    let encodedSize = Int(outputBufferList.mBuffers.mDataByteSize)
    guard encodedSize > 0 else { return }  // priming frame — drop silently
    let aacData = Data(bytes: outputBuffer, count: encodedSize)

    // Append raw AAC-ELD frame to fMP4 writer (no AU header — fMP4 uses raw frames)
    fragmentWriter?.appendAudioSample(aacData)
  }

  /// Convert PCM audio data to Float32 at 16kHz mono.
  private static func convertToFloat32At16kHz(
    _ data: Data, sourceASBD: AudioStreamBasicDescription
  ) -> Data {
    let sourceSampleRate = sourceASBD.mSampleRate
    let sourceChannels = Int(sourceASBD.mChannelsPerFrame)
    let isFloat = (sourceASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let is16Bit = sourceASBD.mBitsPerChannel == 16
    let bytesPerSample = Int(sourceASBD.mBitsPerChannel / 8)

    var floatSamples: [Float] = []

    if isFloat && bytesPerSample == 4 {
      data.withUnsafeBytes { ptr in
        let floatPtr = ptr.bindMemory(to: Float.self)
        if sourceChannels == 1 {
          floatSamples = Array(floatPtr)
        } else {
          for i in stride(from: 0, to: floatPtr.count, by: sourceChannels) {
            var sum: Float = 0
            for ch in 0..<sourceChannels where i + ch < floatPtr.count {
              sum += floatPtr[i + ch]
            }
            floatSamples.append(sum / Float(sourceChannels))
          }
        }
      }
    } else if is16Bit {
      data.withUnsafeBytes { ptr in
        let int16Ptr = ptr.bindMemory(to: Int16.self)
        for i in stride(from: 0, to: int16Ptr.count, by: sourceChannels) {
          var sum: Float = 0
          for ch in 0..<sourceChannels where i + ch < int16Ptr.count {
            sum += Float(int16Ptr[i + ch]) / 32768.0
          }
          floatSamples.append(sum / Float(sourceChannels))
        }
      }
    } else {
      return Data()
    }

    // Resample to 16kHz if needed
    if abs(sourceSampleRate - 16000) > 1 {
      let ratio = 16000.0 / sourceSampleRate
      let outputCount = Int(Double(floatSamples.count) * ratio)
      var resampled = [Float](repeating: 0, count: outputCount)
      for i in 0..<outputCount {
        let srcIdx = Double(i) / ratio
        let idx = Int(srcIdx)
        let frac = Float(srcIdx - Double(idx))
        if idx + 1 < floatSamples.count {
          resampled[i] = floatSamples[idx] * (1 - frac) + floatSamples[idx + 1] * frac
        } else if idx < floatSamples.count {
          resampled[i] = floatSamples[idx]
        }
      }
      floatSamples = resampled
    }

    return floatSamples.withUnsafeBytes { Data($0) }
  }

  /// Create an AAC-ELD encoder (PCM Float32 16kHz mono → AAC-ELD 24kbps).
  private static func createAudioEncoder(logger: Logger) -> AudioConverterRef? {
    var inputDesc = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    var outputDesc = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatMPEG4AAC_ELD,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: 480,
      mBytesPerFrame: 0,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 0,
      mReserved: 0
    )

    var converter: AudioConverterRef?
    let status = AudioConverterNew(&inputDesc, &outputDesc, &converter)
    guard status == noErr, let converter else {
      logger.error("AudioConverter (monitoring encoder) create failed: \(status)")
      return nil
    }

    var bitrate: UInt32 = 24000
    AudioConverterSetProperty(
      converter, kAudioConverterEncodeBitRate,
      UInt32(MemoryLayout<UInt32>.size), &bitrate)

    return converter
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

// MARK: - Audio Converter Callback Data

/// Helper for passing PCM data through the AudioConverter encoder C callback.
private struct AudioEncoderInput {
  var srcData: UnsafeRawPointer?
  var srcSize: UInt32
  var consumed: Bool
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
