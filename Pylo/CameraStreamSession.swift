@preconcurrency import AVFoundation
import AudioToolbox
import CoreImage
@preconcurrency import CoreMedia
import Foundation
import SRTP
import VideoToolbox
import os

// MARK: - Camera Stream Session

/// Holds all state for a single streaming session: addresses, ports, SRTP keys, and the
/// video capture + RTP pipeline.
nonisolated final class CameraStreamSession: @unchecked Sendable {

  let sessionID: Data
  let controllerAddress: String
  let controllerVideoPort: UInt16
  let controllerAudioPort: UInt16

  // Shared SRTP keys (both sides use the same key material)
  let videoSRTPKey: Data
  let videoSRTPSalt: Data
  let audioSRTPKey: Data
  let audioSRTPSalt: Data

  let localAddress: String
  let localVideoPort: UInt16
  let localAudioPort: UInt16

  let videoSSRC: UInt32
  let audioSSRC: UInt32

  let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CameraStream")

  // Video pipeline
  private var captureSession: AVCaptureSession?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var compressionSession: VTCompressionSession?
  let captureQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).camera.capture")
  let rtpQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).camera.rtp")

  // Video UDP — BSD socket (immune to ICMP route-poisoning that kills NWConnection)
  private var videoSocketFD: Int32 = -1
  private var controllerVideoAddr: sockaddr_in?

  // RTP state
  private var sequenceNumber: UInt16 = 0
  private var rtpTimestamp: UInt32 = 0
  private var lastSentRTPTimestamp: UInt32 = 0  // for RTCP SR (timestamp of last sent frame)
  private var encodeFrameCount: Int = 0  // captureQueue only
  private var captureFrameCount: Int = 0  // captureQueue only
  private let motionFrameInterval = 15
  private let luxFrameInterval = 60
  private var rtpFrameCount: Int = 0  // rtpQueue only
  private var packetsSent: Int = 0
  private var octetsSent: Int = 0
  private var targetFPS: Int = 30
  private var rtpPayloadType: UInt8 = 99

  // SRTP state
  private var srtpContext: SRTPContext?

  // Reusable RTP packet buffer — avoids per-packet heap allocation.
  // Accessed exclusively on rtpQueue (serial), so no synchronization needed.
  var rtpBuffer = Data()  // rtpQueue

  // Reusable receive buffer for incoming audio UDP packets (rtpQueue only).
  var audioRecvBuffer = [UInt8](repeating: 0, count: 2048)

  // RTCP timer
  private var rtcpTimer: DispatchSourceTimer?

  // Audio pipeline (microphone → controller)
  // These fields are accessed from CameraStreamSession+Audio.swift (same module)
  // so they cannot be `private`.  All mutable audio RTP state is owned by rtpQueue;
  // audioOutput and audioConverter are owned by captureQueue.
  var audioOutput: AVCaptureAudioDataOutput?  // captureQueue
  var audioConverter: AudioConverterRef?  // captureQueue
  var audioSRTPContext: SRTPContext?  // rtpQueue
  var audioRTPSeq: UInt16 = 0  // rtpQueue
  var audioRTPTimestamp: UInt32 = 0  // rtpQueue
  var audioPayloadType: UInt8 = 110  // set once at init
  var audioPacketsSent: Int = 0  // rtpQueue
  var audioOctetsSent: Int = 0  // rtpQueue
  var audioRTCPTimer: DispatchSourceTimer?  // rtpQueue
  /// Optional video motion detector — called every `motionFrameInterval` frames.
  /// Protected by a lock: written from the server queue, read from captureQueue.
  private let _videoMotionDetector = OSAllocatedUnfairLock<VideoMotionDetector?>(initialState: nil)
  var videoMotionDetector: VideoMotionDetector? {
    get { _videoMotionDetector.withLock { $0 } }
    set { _videoMotionDetector.withLock { $0 = newValue } }
  }

  /// Optional ambient light detector — called every `luxFrameInterval` frames.
  private let _ambientLightDetector = OSAllocatedUnfairLock<AmbientLightDetector?>(
    initialState: nil)
  var ambientLightDetector: AmbientLightDetector? {
    get { _ambientLightDetector.withLock { $0 } }
    set { _ambientLightDetector.withLock { $0 = newValue } }
  }

  // Audio flags — written from the server queue, read from captureQueue/rtpQueue.
  private struct AudioFlags {
    var isMuted: Bool = false
    var speakerMuted: Bool = false
    var speakerVolume: Int = 100
    var playerStarted: Bool = false
  }
  private let audioFlags = OSAllocatedUnfairLock(initialState: AudioFlags())

  // Audio RTP stats — written on captureQueue, read on rtpQueue for RTCP SR.
  struct AudioRTPStats {
    var timestamp: UInt32 = 0
    var packetsSent: Int = 0
    var octetsSent: Int = 0
  }
  let audioRTPStats = OSAllocatedUnfairLock(initialState: AudioRTPStats())

  var isMuted: Bool {
    get { audioFlags.withLock { $0.isMuted } }
    set { audioFlags.withLock { $0.isMuted = newValue } }
  }
  var speakerMuted: Bool {
    get { audioFlags.withLock { $0.speakerMuted } }
    set { audioFlags.withLock { $0.speakerMuted = newValue } }
  }
  var speakerVolume: Int {
    get { audioFlags.withLock { $0.speakerVolume } }
    set { audioFlags.withLock { $0.speakerVolume = newValue } }
  }

  // Audio UDP — single BSD socket for both send and receive.
  // Using a raw BSD socket avoids two NWConnection/NWListener issues:
  // 1. Port conflicts (NWConnection + NWListener can't share the same local port)
  // 2. ICMP poisoning (connected UDP sockets propagate ICMP errors to the kernel,
  //    which poisons the route to the host and kills ALL connections including video)
  var audioSocketFD: Int32 = -1
  private var audioReadSource: DispatchSourceRead?
  var controllerAudioAddr: sockaddr_in?

  // Audio pipeline (controller → speaker)
  var audioDecoder: AudioConverterRef?
  var audioEngine: AVAudioEngine?
  var audioPlayerNode: AVAudioPlayerNode?
  var audioPlayerStarted: Bool {
    get { audioFlags.withLock { $0.playerStarted } }
    set { audioFlags.withLock { $0.playerStarted = newValue } }
  }
  var incomingSRTPContext: SRTPContext?
  /// Cached audio format for playback buffers (Float32, 16kHz, mono).
  let playbackFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

  // Delegate retention — stored as properties instead of ObjC associated objects
  private var videoCaptureDelegate: VideoCaptureDelegate?
  private var audioCaptureDelegate: AudioCaptureDelegate?

  // Snapshot caching — periodically grab a JPEG from the video stream.
  // The callback is set from the server queue and read from captureQueue,
  // so it must be synchronized.
  private let _onSnapshotFrame = OSAllocatedUnfairLock<((Data) -> Void)?>(initialState: nil)
  var onSnapshotFrame: ((Data) -> Void)? {
    get { _onSnapshotFrame.withLock { $0 } }
    set { _onSnapshotFrame.withLock { $0 = newValue } }
  }
  private var snapshotFrameCounter = 0
  private let snapshotInterval = 30  // every ~1s at 30fps
  private let snapshotCIContext: CIContext

  // Audio encoder state — accumulates PCM until we have a full AAC-ELD frame
  var pcmAccumulator = Data()
  let aacFrameSamples = 480  // AAC-ELD frame size at 16kHz

  var audioSampleCount: Int = 0  // captureQueue only
  var incomingAudioPacketCount: Int = 0  // rtpQueue only

  init(
    sessionID: Data,
    controllerAddress: String, controllerVideoPort: UInt16, controllerAudioPort: UInt16,
    videoSRTPKey: Data, videoSRTPSalt: Data,
    audioSRTPKey: Data, audioSRTPSalt: Data,
    localAddress: String, localVideoPort: UInt16, localAudioPort: UInt16,
    videoSSRC: UInt32, audioSSRC: UInt32,
    ciContext: CIContext
  ) {
    self.sessionID = sessionID
    self.controllerAddress = controllerAddress
    self.controllerVideoPort = controllerVideoPort
    self.controllerAudioPort = controllerAudioPort
    self.videoSRTPKey = videoSRTPKey
    self.videoSRTPSalt = videoSRTPSalt
    self.audioSRTPKey = audioSRTPKey
    self.audioSRTPSalt = audioSRTPSalt
    self.localAddress = localAddress
    self.localVideoPort = localVideoPort
    self.localAudioPort = localAudioPort
    self.videoSSRC = videoSSRC
    self.audioSSRC = audioSSRC
    self.snapshotCIContext = ciContext
  }

  deinit {
    // Log a warning if resources are still live — stopStreaming() should
    // always be called explicitly before the session is released.
    // We cannot call stopStreaming() from deinit because it uses
    // rtpQueue.sync, which deadlocks if deinit runs on rtpQueue itself
    // (e.g., when the last strong ref drops inside a weak-self callback).
    if captureSession != nil || videoSocketFD >= 0 || audioSocketFD >= 0 {
      logger.error("CameraStreamSession deallocated without stopStreaming() — resource leak")
    }
  }

  /// Start streaming. Returns `true` on success, `false` if socket setup failed.
  /// If `existingCaptureSession` is provided (handed off from monitoring), the session
  /// is reconfigured in-place without stopping the camera — saving ~500ms of startup.
  @discardableResult
  func startStreaming(
    width: Int, height: Int, fps: Int, bitrate: Int, payloadType: UInt8,
    audioPayloadType: UInt8 = 110, camera: AVCaptureDevice, rotationAngle: Int = 90,
    swapDimensions: Bool = true, existingCaptureSession: AVCaptureSession? = nil
  ) -> Bool {
    logger.info(
      "Starting stream: \(width)x\(height)@\(fps)fps, \(bitrate)kbps, PT=\(payloadType) → \(self.controllerAddress):\(self.controllerVideoPort)"
    )
    logger.info(
      "SRTP key=\(self.videoSRTPKey.count)B salt=\(self.videoSRTPSalt.count)B SSRC=\(self.videoSSRC)"
    )

    self.targetFPS = fps
    self.rtpPayloadType = payloadType
    self.audioPayloadType = audioPayloadType
    // Safe to reset from any queue here: the capture pipeline hasn't started yet
    // (setupCapture is called below), so no captureQueue or rtpQueue work exists.
    // Start seq/ts at low values — some SRTP receivers mis-estimate the
    // rollover counter when the first sequence number is > 2^15, causing
    // every authentication check to fail (black video).
    self.sequenceNumber = 0
    self.rtpTimestamp = 0
    self.packetsSent = 0
    self.octetsSent = 0
    self.audioRTPSeq = 0
    self.audioRTPTimestamp = 0
    self.audioPacketsSent = 0
    self.audioOctetsSent = 0
    self.pcmAccumulator = Data()

    // Initialize SRTP with shared keys (both sides use the same key material)
    if audioSRTPKey.isEmpty || audioSRTPSalt.isEmpty {
      logger.warning("Audio SRTP keys are EMPTY — audio encryption will fail")
    }
    srtpContext = SRTPContext(masterKey: videoSRTPKey, masterSalt: videoSRTPSalt)
    audioSRTPContext = SRTPContext(masterKey: audioSRTPKey, masterSalt: audioSRTPSalt)
    incomingSRTPContext = SRTPContext(masterKey: audioSRTPKey, masterSalt: audioSRTPSalt)

    // Video: BSD UDP socket (immune to ICMP route-poisoning that kills NWConnection)
    let videoFD = socket(AF_INET, SOCK_DGRAM, 0)
    guard videoFD >= 0 else {
      logger.error("Failed to create video UDP socket: errno \(errno)")
      return false
    }

    var videoBindAddr = sockaddr_in()
    videoBindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    videoBindAddr.sin_family = sa_family_t(AF_INET)
    videoBindAddr.sin_port = localVideoPort.bigEndian
    videoBindAddr.sin_addr.s_addr = inet_addr(localAddress)

    let videoBindResult = withUnsafePointer(to: &videoBindAddr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(videoFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard videoBindResult == 0 else {
      logger.error("Failed to bind video socket to port \(self.localVideoPort): errno \(errno)")
      close(videoFD)
      return false
    }

    let videoFlags = fcntl(videoFD, F_GETFL)
    _ = fcntl(videoFD, F_SETFL, videoFlags | O_NONBLOCK)

    self.videoSocketFD = videoFD
    logger.info("Video BSD socket bound to port \(self.localVideoPort)")

    var vidAddr = sockaddr_in()
    vidAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    vidAddr.sin_family = sa_family_t(AF_INET)
    vidAddr.sin_port = controllerVideoPort.bigEndian
    vidAddr.sin_addr.s_addr = inet_addr(controllerAddress)
    self.controllerVideoAddr = vidAddr

    // Start capture pipeline immediately (BSD socket is ready after bind)
    let encWidth = swapDimensions ? height : width
    let encHeight = swapDimensions ? width : height
    self.setupCompression(width: encWidth, height: encHeight, fps: fps, bitrate: bitrate)
    self.setupCapture(
      width: width, height: height, fps: fps, camera: camera, rotationAngle: rotationAngle,
      existingSession: existingCaptureSession)
    self.startRTCPTimer()

    // Audio: single BSD UDP socket for both send and receive.
    // Avoids NWConnection port conflicts and ICMP route-poisoning issues.
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else {
      logger.error("Failed to create audio UDP socket: errno \(errno)")
      stopStreaming()
      return false
    }

    // Bind to our advertised local audio port
    var bindAddr = sockaddr_in()
    bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    bindAddr.sin_family = sa_family_t(AF_INET)
    bindAddr.sin_port = localAudioPort.bigEndian
    bindAddr.sin_addr.s_addr = inet_addr(localAddress)

    let bindResult = withUnsafePointer(to: &bindAddr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      logger.error("Failed to bind audio socket to port \(self.localAudioPort): errno \(errno)")
      close(fd)
      stopStreaming()
      return false
    }

    // Set non-blocking
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    self.audioSocketFD = fd
    logger.info("Audio BSD socket bound to port \(self.localAudioPort)")

    // Store controller audio address for sendto()
    var ctrlAddr = sockaddr_in()
    ctrlAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    ctrlAddr.sin_family = sa_family_t(AF_INET)
    ctrlAddr.sin_port = controllerAudioPort.bigEndian
    ctrlAddr.sin_addr.s_addr = inet_addr(controllerAddress)
    self.controllerAudioAddr = ctrlAddr

    // Start async receive via GCD read source
    let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: rtpQueue)
    readSource.setEventHandler { [weak self] in
      self?.readAudioSocket()
    }
    readSource.setCancelHandler {
      close(fd)
    }
    readSource.resume()
    self.audioReadSource = readSource

    if self.audioConverter == nil {
      self.setupAudioEncoder()
    }
    self.startAudioRTCPTimer()
    self.setupAudioDecoder()
    self.setupAudioPlayback()
    return true
  }

  func stopStreaming() {
    tearDown(keepCaptureSession: false)
  }

  /// Hand off the running AVCaptureSession for reuse by the monitoring session.
  /// Tears down all streaming resources (sockets, SRTP, audio, timers) but
  /// leaves the AVCaptureSession running. Returns nil if no session is active.
  func handoff() -> AVCaptureSession? {
    return tearDown(keepCaptureSession: true)
  }

  /// Shared teardown logic. When `keepCaptureSession` is true, the
  /// AVCaptureSession is extracted and returned instead of being stopped.
  @discardableResult
  private func tearDown(keepCaptureSession: Bool) -> AVCaptureSession? {
    dispatchPrecondition(condition: .notOnQueue(captureQueue))
    dispatchPrecondition(condition: .notOnQueue(rtpQueue))
    if keepCaptureSession {
      logger.info("Handing off stream session")
    } else {
      logger.info("Stopping stream")
    }

    // Cancel all timers before draining queues so no timer fires in the
    // window between drain and cancellation.
    rtcpTimer?.cancel()
    rtcpTimer = nil
    audioRTCPTimer?.cancel()
    audioRTCPTimer = nil

    let session = captureSession
    if keepCaptureSession {
      // Hand off — don't stop the session, just detach it
      captureSession = nil
    } else {
      // stopRunning() is synchronous — it blocks until the session fully
      // stops delivering frames. Calling it directly (rather than async)
      // ensures the VTCompressionSession won't receive new frames after
      // we invalidate it below.
      captureSession?.stopRunning()
      captureSession = nil
    }

    // Drain in-flight captureQueue blocks so no concurrent encodeFrame or
    // encodeAndSendAudioFrame call is mid-execution when we dispose resources.
    captureQueue.sync {}

    if let cs = compressionSession {
      // Flush in-flight async encodes before invalidating (undefined behavior otherwise)
      VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: .positiveInfinity)
      VTCompressionSessionInvalidate(cs)
    }
    compressionSession = nil

    // Drain any blocks dispatched to rtpQueue (from VT output callback or
    // audio read source) before we proceed to close sockets. Moved outside
    // the if-let so audio-only work is also drained.
    rtpQueue.sync {}

    // Audio mic cleanup
    audioOutput = nil
    videoCaptureDelegate = nil
    audioCaptureDelegate = nil

    // Safe to dispose here: encodeAndSendAudioFrame uses audioConverter synchronously
    // on captureQueue (already drained above), and only dispatches the encoded result
    // to rtpQueue (also drained above). No in-flight code references this converter.
    if let enc = audioConverter {
      AudioConverterDispose(enc)
    }
    audioConverter = nil
    pcmAccumulator = Data()

    // Capture FD values, then invalidate the members immediately so that
    // any in-flight timer/read handlers on rtpQueue see -1 and bail via
    // their guard checks before we close the actual file descriptors.
    let readSource = audioReadSource
    let videoFD = videoSocketFD
    let audioFD = audioSocketFD
    let decoder = audioDecoder
    let player = audioPlayerNode
    let engine = audioEngine
    let incomingSRTP = incomingSRTPContext

    audioReadSource = nil
    videoSocketFD = -1
    controllerVideoAddr = nil
    srtpContext = nil
    audioSocketFD = -1
    controllerAudioAddr = nil
    audioSRTPContext = nil

    // Cancel the read source. Its cancel handler closes the audio FD.
    readSource?.cancel()

    rtpQueue.sync {
      // By the time this executes, the cancelled read source's cancel handler
      // and any in-flight sendVideoUDP/sendAudioUDP/readAudioSocket calls have drained.
      if videoFD >= 0 { close(videoFD) }
      // Close audio FD here if there was no read source to own it.
      if readSource == nil, audioFD >= 0 { close(audioFD) }
      if let dec = decoder { AudioConverterDispose(dec) }
      _ = incomingSRTP  // prevent premature dealloc until after queue drains
    }

    // Stop the audio engine/player outside of rtpQueue — AVAudioEngine
    // is not documented as thread-safe when stopped from an arbitrary queue.
    player?.stop()
    engine?.stop()

    // Remaining state cleanup (FDs already invalidated above)
    audioSampleCount = 0
    incomingAudioPacketCount = 0
    audioPlayerNode = nil
    audioPlayerStarted = false
    audioEngine = nil
    audioDecoder = nil
    incomingSRTPContext = nil

    return keepCaptureSession ? session : nil
  }

  // MARK: - Video Capture

  private func setupCapture(
    width: Int, height: Int, fps: Int, camera: AVCaptureDevice, rotationAngle: Int = 90,
    existingSession: AVCaptureSession? = nil
  ) {
    do {
      try camera.lockForConfiguration()
      // Find closest frame rate range
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
      self.encodeFrame(pixelBuffer, pts: pts)
    }
    output.setSampleBufferDelegate(delegate, queue: captureQueue)

    let session: AVCaptureSession
    if let existing = existingSession {
      // Reuse the monitoring session's running AVCaptureSession — reconfigure
      // in-place to avoid the ~500ms cold-start of creating a new one.
      session = existing
      logger.info("Reusing handed-off capture session (already running)")

      session.beginConfiguration()

      // Remove monitoring's outputs (video, possibly audio)
      for old in session.outputs { session.removeOutput(old) }

      // Change preset if needed (monitoring always uses .hd1920x1080)
      let targetPreset: AVCaptureSession.Preset =
        width > 1280 ? .hd1920x1080 : width > 640 ? .hd1280x720 : .medium
      if session.sessionPreset != targetPreset { session.sessionPreset = targetPreset }

      // Add streaming video output
      if session.canAddOutput(output) { session.addOutput(output) }

      // Add mic input if monitoring didn't have it
      let hasMic = session.inputs.contains { input in
        (input as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true
      }
      if !hasMic, let mic = AVCaptureDevice.default(for: .audio),
        let micInput = try? AVCaptureDeviceInput(device: mic),
        session.canAddInput(micInput)
      {
        session.addInput(micInput)
      }

      // Add streaming audio output
      let audioOut = AVCaptureAudioDataOutput()
      let audioDelegate = AudioCaptureDelegate { [weak self] sampleBuffer in
        self?.handleAudioSampleBuffer(sampleBuffer)
      }
      audioOut.setSampleBufferDelegate(audioDelegate, queue: captureQueue)
      if session.canAddOutput(audioOut) {
        session.addOutput(audioOut)
        self.audioOutput = audioOut
        self.audioCaptureDelegate = audioDelegate
      }

      session.commitConfiguration()
      // Session is already running — no startRunning() needed
    } else {
      // Cold start — create a new AVCaptureSession from scratch
      session = AVCaptureSession()
      session.sessionPreset = width > 1280 ? .hd1920x1080 : width > 640 ? .hd1280x720 : .medium

      do {
        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) { session.addInput(input) }
      } catch {
        logger.error("Camera input error: \(error)")
        return
      }

      if session.canAddOutput(output) { session.addOutput(output) }

      // Add microphone input for audio capture
      if let mic = AVCaptureDevice.default(for: .audio),
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
          self.audioOutput = audioOut
          self.audioCaptureDelegate = audioDelegate
          logger.info("Microphone audio capture added to session")
        }
      } else {
        logger.error("Failed to add microphone input")
      }

      captureQueue.async { [weak self] in
        session.startRunning()
        self?.logger.info("Capture session running: \(session.isRunning)")
      }
    }

    // Rotate output to match device orientation.
    if let connection = output.connection(with: .video),
      connection.isVideoRotationAngleSupported(CGFloat(rotationAngle))
    {
      connection.videoRotationAngle = CGFloat(rotationAngle)
    }

    self.captureSession = session
    self.videoOutput = output
    self.videoCaptureDelegate = delegate

    // Pre-create the audio encoder so it's ready when mic samples arrive.
    // Without this, audio samples arriving before the audio UDP is ready are silently dropped.
    if self.audioConverter == nil {
      self.setupAudioEncoder()
    }
  }

  // MARK: - H.264 Compression

  private func setupCompression(width: Int, height: Int, fps: Int, bitrate: Int) {
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
      return
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
      value: (fps * 2) as CFNumber)  // Keyframe every 2 seconds
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
      value: 2.0 as CFNumber)  // Also set duration-based interval
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_ExpectedFrameRate,
      value: fps as CFNumber)
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_AllowFrameReordering,
      value: kCFBooleanFalse)
    // Data rate limit: cap at average bytes per second over a 1-second window
    let bytesPerSecond = (bitrate * 1000 / 8) as CFNumber
    let one = 1.0 as CFNumber
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_DataRateLimits,
      value: [bytesPerSecond, one] as CFArray)

    VTCompressionSessionPrepareToEncodeFrames(cs)
    self.compressionSession = cs
  }

  private func encodeFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    dispatchPrecondition(condition: .onQueue(captureQueue))
    guard let cs = compressionSession else { return }

    encodeFrameCount += 1

    // Periodically cache a JPEG for snapshot requests while streaming.
    // Render to CGImage synchronously (fast — just materializes the lazy CIImage),
    // then dispatch JPEG compression to a background queue to avoid blocking
    // video frame delivery on captureQueue.
    snapshotFrameCounter += 1
    if snapshotFrameCounter >= snapshotInterval, let callback = onSnapshotFrame {
      snapshotFrameCounter = 0
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      if let cgImage = snapshotCIContext.createCGImage(ciImage, from: ciImage.extent) {
        let ctx = snapshotCIContext
        DispatchQueue.global(qos: .utility).async {
          let rendered = CIImage(cgImage: cgImage)
          if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let jpeg = ctx.jpegRepresentation(
              of: rendered, colorSpace: colorSpace, options: [:])
          {
            callback(jpeg)
          }
        }
      }
    }

    // Force keyframe on first frame
    let props: CFDictionary? =
      encodeFrameCount == 1
      ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
      : nil

    var flags = VTEncodeInfoFlags()
    let status = VTCompressionSessionEncodeFrame(
      cs,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: pts,
      duration: .invalid,
      frameProperties: props,
      infoFlagsOut: &flags,
      outputHandler: { [weak self] status, _, sampleBuffer in
        autoreleasepool {
          if status != noErr {
            self?.logger.error("Encode output error: \(status)")
            return
          }
          guard let sampleBuffer, let self else { return }
          // CMSampleBuffer is immutable after creation and safe to send across threads.
          nonisolated(unsafe) let buffer = sampleBuffer
          self.rtpQueue.async {
            self.processEncodedFrame(buffer)
          }
        }
      }
    )
    if status != noErr {
      logger.error("VTCompressionSessionEncodeFrame failed: \(status)")
    }
  }

  // MARK: - RTP Packetization

  private func processEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
    dispatchPrecondition(condition: .onQueue(rtpQueue))
    guard let dataBuffer = sampleBuffer.dataBuffer else { return }

    // Get H.264 NAL units from the sample buffer
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(
      dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard let ptr = dataPointer, totalLength > 0 else { return }

    // Copy the frame data — CMBlockBuffer's pointer is only valid for this call,
    // and NAL slices (below) must outlive it. This single copy is amortized across
    // all NAL units since Data slices share the backing buffer via COW.
    let data = Data(bytes: ptr, count: totalLength)

    // Check for keyframe — if so, send SPS/PPS first
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    rtpFrameCount += 1
    if isKeyframe || rtpFrameCount % 300 == 1 {
      logger.debug(
        "Frame \(self.rtpFrameCount) encoded: \(totalLength) bytes, keyframe=\(isKeyframe)")
    }

    if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
      sendParameterSets(formatDesc)
    }

    // Parse AVCC-format NAL units (4-byte length prefix)
    // First pass: collect non-SEI NAL units
    var nalUnits: [Data] = []
    var offset = 0
    while offset + 4 <= data.count {
      let nalLength =
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8
        | Int(data[offset + 3])
      offset += 4
      guard nalLength > 0, offset + nalLength <= data.count else { break }

      // Data subscript returns a slice sharing the backing buffer (no copy).
      nalUnits.append(data[offset..<offset + nalLength])
      offset += nalLength
    }

    // Second pass: send with correct marker bits
    for (i, nal) in nalUnits.enumerated() {
      let isLast = (i == nalUnits.count - 1)
      sendNALUnit(nal, marker: isLast)
    }

    // Advance RTP timestamp (90kHz clock)
    lastSentRTPTimestamp = rtpTimestamp
    rtpTimestamp &+= UInt32(90000 / targetFPS)
  }

  private func sendParameterSets(_ formatDesc: CMFormatDescription) {
    // Extract SPS
    var spsSize = 0
    var spsCount = 0
    var spsPtr: UnsafePointer<UInt8>?
    guard
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr,
        parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
      ) == noErr, let spsPtr
    else { return }
    let sps = Data(bytes: spsPtr, count: spsSize)

    // Extract PPS
    var ppsSize = 0
    var ppsPtr: UnsafePointer<UInt8>?
    guard
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr,
        parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
      ) == noErr, let ppsPtr
    else { return }
    let pps = Data(bytes: ppsPtr, count: ppsSize)

    // Send SPS and PPS as individual single-NAL-unit RTP packets
    // marker=false because the IDR slice follows in the same access unit
    sendRTPPacket(payload: sps, marker: false)
    sendRTPPacket(payload: pps, marker: false)
  }

  /// Send a single NAL unit, fragmenting into FU-A packets if > MTU.
  /// `marker` should be true only for the last NAL unit of an access unit (RFC 6184 §5.1).
  private func sendNALUnit(_ nal: Data, marker: Bool) {
    let maxPayload = 1200 - 12  // MTU minus RTP header

    if nal.count <= maxPayload {
      // Single NAL unit packet — marker only if this is the last NAL of the access unit
      sendRTPPacket(payload: nal, marker: marker)
    } else {
      // FU-A fragmentation (RFC 6184 §5.8)
      // Writes FU indicator + FU header + chunk directly into rtpBuffer,
      // avoiding a per-fragment Data allocation.
      let nalHeader = nal[nal.startIndex]
      let nri = nalHeader & 0x60  // NRI bits
      let nalType = nalHeader & 0x1F  // NAL unit type

      var offset = 1  // Skip original NAL header
      let nalBody = nal.dropFirst()
      let total = nalBody.count

      while offset - 1 < total {
        let remaining = total - (offset - 1)
        let chunkSize = min(maxPayload - 2, remaining)  // -2 for FU indicator + FU header
        let isFirst = (offset == 1)
        let isLast = (chunkSize == remaining)

        let fuIndicator: UInt8 = nri | 28  // Type 28 = FU-A
        var fuHeader: UInt8 = nalType
        if isFirst { fuHeader |= 0x80 }  // Start bit
        if isLast { fuHeader |= 0x40 }  // End bit

        writeRTPHeader(marker: isLast && marker, payloadSize: 2 + chunkSize)
        rtpBuffer.append(fuIndicator)
        rtpBuffer.append(fuHeader)
        rtpBuffer.append(nal[(nal.startIndex + offset)..<(nal.startIndex + offset + chunkSize)])
        encryptAndSendVideo(payloadSize: 2 + chunkSize)

        offset += chunkSize
      }
    }
  }

  private func sendRTPPacket(payload: Data, marker: Bool) {
    writeRTPHeader(marker: marker, payloadSize: payload.count)
    rtpBuffer.append(payload)
    encryptAndSendVideo(payloadSize: payload.count)
  }

  /// Write the 12-byte RTP header into rtpBuffer and advance the sequence number.
  private func writeRTPHeader(marker: Bool, payloadSize: Int) {
    dispatchPrecondition(condition: .onQueue(rtpQueue))
    rtpBuffer.count = 0
    rtpBuffer.reserveCapacity(12 + payloadSize)

    // RTP header (12 bytes) per RFC 3550
    rtpBuffer.append(0x80)  // V=2, P=0, X=0, CC=0
    rtpBuffer.append((marker ? 0x80 : 0x00) | (rtpPayloadType & 0x7F))  // M bit + dynamic PT
    rtpBuffer.append(UInt8(sequenceNumber >> 8))
    rtpBuffer.append(UInt8(sequenceNumber & 0xFF))
    rtpBuffer.append(UInt8((rtpTimestamp >> 24) & 0xFF))
    rtpBuffer.append(UInt8((rtpTimestamp >> 16) & 0xFF))
    rtpBuffer.append(UInt8((rtpTimestamp >> 8) & 0xFF))
    rtpBuffer.append(UInt8(rtpTimestamp & 0xFF))
    rtpBuffer.append(UInt8((videoSSRC >> 24) & 0xFF))
    rtpBuffer.append(UInt8((videoSSRC >> 16) & 0xFF))
    rtpBuffer.append(UInt8((videoSSRC >> 8) & 0xFF))
    rtpBuffer.append(UInt8(videoSSRC & 0xFF))

    sequenceNumber &+= 1
  }

  /// Encrypt rtpBuffer with SRTP and send via UDP socket.
  private func encryptAndSendVideo(payloadSize: Int) {
    let packet: Data
    if let ctx = srtpContext {
      guard let protected = ctx.protect(rtpBuffer) else { return }
      packet = protected
    } else {
      packet = rtpBuffer
    }

    packetsSent += 1
    octetsSent += payloadSize
    sendVideoUDP(packet)
  }

  /// Send data via the BSD video socket to the controller's video port.
  private func sendVideoUDP(_ data: Data) {
    guard videoSocketFD >= 0, var addr = controllerVideoAddr else { return }
    data.withUnsafeBytes { buf in
      guard let base = buf.baseAddress else { return }
      withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
          _ = sendto(
            videoSocketFD, base, buf.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
  }

  // MARK: - RTCP Sender Report

  private func startRTCPTimer() {
    let timer = DispatchSource.makeTimerSource(queue: rtpQueue)
    timer.schedule(deadline: .now() + 0.5, repeating: 5.0)
    timer.setEventHandler { [weak self] in
      self?.sendRTCPSenderReport()
    }
    timer.resume()
    self.rtcpTimer = timer
  }

  private func sendRTCPSenderReport() {
    dispatchPrecondition(condition: .onQueue(rtpQueue))
    guard let ctx = srtpContext else { return }

    let sr = Self.buildRTCPSenderReport(
      ssrc: videoSSRC, rtpTimestamp: lastSentRTPTimestamp,
      packetsSent: packetsSent, octetsSent: octetsSent)
    guard let srtcpPacket = ctx.protectRTCP(sr) else { return }
    sendVideoUDP(srtcpPacket)
    logger.debug(
      "Sent RTCP-SR: packets=\(self.packetsSent) octets=\(self.octetsSent)")
  }
}
