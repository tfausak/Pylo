@preconcurrency import AVFoundation
import AudioToolbox
@preconcurrency import CoreMedia
import Foundation
import Locked
import SRTP
import Sensors
import VideoToolbox
import os

// MARK: - Camera Stream Session

/// Holds all state for a single streaming session: addresses, ports, SRTP keys, and the
/// video capture + RTP pipeline.
///
/// `@unchecked Sendable` is required because AVCaptureSession, VTCompressionSession,
/// AudioConverterRef, AVAudioEngine, and DispatchSourceTimer are not Sendable.
/// Thread safety is ensured by queue ownership (captureQueue/rtpQueue) and Locked
/// wrappers for cross-queue state.
public nonisolated final class CameraStreamSession: @unchecked Sendable {

  public let sessionID: Data
  public let controllerAddress: String
  public let controllerVideoPort: UInt16
  public let controllerAudioPort: UInt16

  // Shared SRTP keys (both sides use the same key material)
  public let videoSRTPKey: Data
  public let videoSRTPSalt: Data
  public let audioSRTPKey: Data
  public let audioSRTPSalt: Data

  public let localAddress: String
  public let localVideoPort: UInt16
  public let localAudioPort: UInt16

  public let videoSSRC: UInt32
  public let audioSSRC: UInt32

  public let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Streaming", category: "CameraStream")

  // Video pipeline
  private var captureSession: AVCaptureSession?
  private var interruptionObservers: [NSObjectProtocol] = []
  private var videoOutput: AVCaptureVideoDataOutput?
  private var compressionSession: VTCompressionSession?
  public let captureQueue = DispatchQueue(
    label: "\(Bundle.main.bundleIdentifier ?? "Streaming").camera.capture")
  public let audioQueue = DispatchQueue(
    label: "\(Bundle.main.bundleIdentifier ?? "Streaming").camera.audio")
  public let rtpQueue = DispatchQueue(
    label: "\(Bundle.main.bundleIdentifier ?? "Streaming").camera.rtp")

  // Video UDP — BSD socket (immune to ICMP route-poisoning that kills NWConnection)
  private var videoSocketFD: Int32 = -1
  private var controllerVideoAddr: sockaddr_in?

  // RTP state
  private var sequenceNumber: UInt16 = 0
  private var rtpTimestamp: UInt32 = 0
  private var lastSentRTPTimestamp: UInt32 = 0  // for RTCP SR (timestamp of last sent frame)
  private var firstPTS: CMTime = .invalid  // PTS of the first frame, for RTP timestamp derivation
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
  // audioOutput and audioConverter are owned by audioQueue.
  var audioOutput: AVCaptureAudioDataOutput?  // audioQueue
  var audioConverter: AudioConverterRef?  // audioQueue
  var audioSRTPContext: SRTPContext?  // rtpQueue
  var audioRTPSeq: UInt16 = 0  // rtpQueue
  var audioRTPTimestamp: UInt32 = 0  // rtpQueue
  var audioPayloadType: UInt8 = 110  // set once at init
  var audioPacketsSent: Int = 0  // rtpQueue
  var audioOctetsSent: Int = 0  // rtpQueue
  var audioRTCPTimer: DispatchSourceTimer?  // rtpQueue
  /// Optional video motion detector — called every `motionFrameInterval` frames.
  /// Protected by a lock: written from the server queue, read from captureQueue.
  private let _videoMotionDetector = Locked<VideoMotionDetector?>(initialState: nil)
  public var videoMotionDetector: VideoMotionDetector? {
    get { _videoMotionDetector.valueUnchecked }
    set { _videoMotionDetector.valueUnchecked = newValue }
  }

  /// Optional ambient light detector — called every `luxFrameInterval` frames.
  private let _ambientLightDetector = Locked<AmbientLightDetector?>(
    initialState: nil)
  public var ambientLightDetector: AmbientLightDetector? {
    get { _ambientLightDetector.valueUnchecked }
    set { _ambientLightDetector.valueUnchecked = newValue }
  }

  // Audio flags — written from the server queue, read from captureQueue/rtpQueue.
  private struct AudioFlags {
    var isMuted: Bool = false
    var speakerMuted: Bool = false
    var speakerVolume: Int = 100
    var playerStarted: Bool = false
  }
  private let audioFlags = Locked(initialState: AudioFlags())

  // Audio RTP stats — written on captureQueue, read on rtpQueue for RTCP SR.
  public struct AudioRTPStats: Sendable {
    var timestamp: UInt32 = 0
    var packetsSent: Int = 0
    var octetsSent: Int = 0
  }
  public let audioRTPStats = Locked(initialState: AudioRTPStats())

  public var isMuted: Bool {
    get { audioFlags.withLock { $0.isMuted } }
    set { audioFlags.withLock { $0.isMuted = newValue } }
  }
  public var speakerMuted: Bool {
    get { audioFlags.withLock { $0.speakerMuted } }
    set { audioFlags.withLock { $0.speakerMuted = newValue } }
  }
  public var speakerVolume: Int {
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
  public let playbackFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

  // Delegate retention — stored as properties instead of ObjC associated objects
  private var videoCaptureDelegate: VideoCaptureDelegate?
  private var audioCaptureDelegate: AudioCaptureDelegate?

  // Snapshot caching — periodically grab a CGImage from the video stream.
  // JPEG encoding is deferred to when HomeKit actually requests a snapshot.
  // The callback is set from the server queue and read from captureQueue,
  // so it must be synchronized.
  private let _onSnapshotFrame = Locked<(@Sendable (CGImage) -> Void)?>(initialState: nil)
  public var onSnapshotFrame: (@Sendable (CGImage) -> Void)? {
    get { _onSnapshotFrame.value }
    set { _onSnapshotFrame.value = newValue }
  }
  private var snapshotFrameCounter = 0
  private var snapshotInterval = 30  // every ~1s, derived from negotiated fps

  // Audio encoder state — accumulates PCM until we have a full AAC-ELD frame
  var pcmAccumulator = Data()
  public let aacFrameSamples = 480  // AAC-ELD frame size at 16kHz

  var audioSampleCount: Int = 0  // audioQueue only
  var incomingAudioPacketCount: Int = 0  // rtpQueue only

  public init(
    sessionID: Data,
    controllerAddress: String, controllerVideoPort: UInt16, controllerAudioPort: UInt16,
    videoSRTPKey: Data, videoSRTPSalt: Data,
    audioSRTPKey: Data, audioSRTPSalt: Data,
    localAddress: String, localVideoPort: UInt16, localAudioPort: UInt16,
    videoSSRC: UInt32, audioSSRC: UInt32
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
  public func startStreaming(
    width: Int, height: Int, fps: Int, bitrate: Int, payloadType: UInt8,
    audioPayloadType: UInt8 = 110, camera: AVCaptureDevice, rotationAngle: Int = 90,
    swapDimensions: Bool = true, existingCaptureSession: AVCaptureSession? = nil,
    microphoneEnabled: Bool = true
  ) -> Bool {
    logger.info(
      "Starting stream: \(width)x\(height)@\(fps)fps, \(bitrate)kbps, PT=\(payloadType) → \(self.controllerAddress):\(self.controllerVideoPort)"
    )
    logger.debug(
      "SRTP key=\(self.videoSRTPKey.count)B salt=\(self.videoSRTPSalt.count)B SSRC=\(self.videoSSRC)"
    )

    self.targetFPS = fps
    self.snapshotInterval = max(1, fps * 2)
    self.rtpPayloadType = payloadType
    self.audioPayloadType = audioPayloadType
    // Safe to reset from any queue here: the capture pipeline hasn't started yet
    // (setupCapture is called below), so no captureQueue or rtpQueue work exists.
    // Start seq/ts at low values — some SRTP receivers mis-estimate the
    // rollover counter when the first sequence number is > 2^15, causing
    // every authentication check to fail (black video).
    self.sequenceNumber = 0
    self.rtpTimestamp = 0
    self.firstPTS = .invalid
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
      // Safe to call from any queue: ownership was transferred to us, so no
      // other code touches this session concurrently.
      existingCaptureSession?.stopRunning()
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
      // Safe to call from any queue: ownership was transferred to us, so no
      // other code touches this session concurrently.
      existingCaptureSession?.stopRunning()
      return false
    }

    let videoFlags = fcntl(videoFD, F_GETFL)
    _ = fcntl(videoFD, F_SETFL, videoFlags | O_NONBLOCK)

    self.videoSocketFD = videoFD
    logger.debug("Video BSD socket bound to port \(self.localVideoPort)")

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
    let captureOK = self.setupCapture(
      width: width, height: height, fps: fps, camera: camera, rotationAngle: rotationAngle,
      existingSession: existingCaptureSession, microphoneEnabled: microphoneEnabled)
    guard captureOK else {
      logger.error("Failed to set up capture pipeline")
      // Safe to call from any queue: ownership was transferred to us, so no
      // other code touches this session concurrently.
      existingCaptureSession?.stopRunning()
      if let compressionSession = self.compressionSession {
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
        self.refconBox = nil
      }
      close(videoFD)
      self.videoSocketFD = -1
      return false
    }
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
    logger.debug("Audio BSD socket bound to port \(self.localAudioPort)")

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

  public func stopStreaming() {
    tearDown(keepCaptureSession: false)
  }

  /// Hand off the running AVCaptureSession for reuse by the monitoring session.
  /// Tears down all streaming resources (sockets, SRTP, audio, timers) but
  /// leaves the AVCaptureSession running. Returns nil if no session is active.
  public func handoff() -> AVCaptureSession? {
    return tearDown(keepCaptureSession: true)
  }

  /// Shared teardown logic. When `keepCaptureSession` is true, the
  /// AVCaptureSession is extracted and returned instead of being stopped.
  @discardableResult
  private func tearDown(keepCaptureSession: Bool) -> AVCaptureSession? {
    dispatchPrecondition(condition: .notOnQueue(captureQueue))
    dispatchPrecondition(condition: .notOnQueue(audioQueue))
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

    removeInterruptionObservers()
    let session = captureSession
    if keepCaptureSession, let session {
      // Remove our outputs so the running session stops delivering frames
      // to our delegates before we dispose encoders/sockets below.
      session.beginConfiguration()
      if let videoOutput { session.removeOutput(videoOutput) }
      if let audioOutput { session.removeOutput(audioOutput) }
      session.commitConfiguration()
      captureSession = nil
    } else {
      // stopRunning() is synchronous — it blocks until the session fully
      // stops delivering frames. Called here on the HAP server queue
      // (never the main thread), which satisfies Apple's threading
      // requirement. Unlike MonitoringCaptureSession, we don't use a
      // dedicated sessionQueue because CameraStreamSession's lifecycle
      // is fully controlled by the HAP server queue.
      captureSession?.stopRunning()
      captureSession = nil
    }

    // Drain in-flight captureQueue blocks so no concurrent encodeFrame call
    // is mid-execution when we dispose resources.
    captureQueue.sync {}

    // Drain in-flight audioQueue blocks so no concurrent handleAudioSampleBuffer
    // or encodeAndSendAudioFrame call is mid-execution when we dispose resources.
    audioQueue.sync {}

    if let cs = compressionSession {
      // Flush in-flight async encodes before invalidating (undefined behavior otherwise)
      VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: .positiveInfinity)
      VTCompressionSessionInvalidate(cs)
    }
    compressionSession = nil
    refconBox = nil

    // Drain any blocks dispatched to rtpQueue (from VT output callback or
    // audio read source) before we proceed to close sockets. Moved outside
    // the if-let so audio-only work is also drained.
    rtpQueue.sync {}

    // Audio mic cleanup
    audioOutput = nil
    videoOutput = nil
    videoCaptureDelegate = nil
    audioCaptureDelegate = nil

    // Safe to dispose here: encodeAndSendAudioFrame uses audioConverter synchronously
    // on audioQueue (already drained above), and only dispatches the encoded result
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
      if readSource == nil, audioFD >= 0 {
        logger.warning("Audio FD open but no read source — closing in fallback path")
        close(audioFD)
      }
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

  @discardableResult
  private func setupCapture(
    width: Int, height: Int, fps: Int, camera: AVCaptureDevice, rotationAngle: Int = 90,
    existingSession: AVCaptureSession? = nil, microphoneEnabled: Bool = true
  ) -> Bool {
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
    if microphoneEnabled {
      configureAudioSessionForVoiceChat(logger: logger)
    }

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
      logger.debug("Reusing handed-off capture session (already running)")

      session.beginConfiguration()

      // Remove monitoring's outputs (video, possibly audio)
      for old in session.outputs { session.removeOutput(old) }

      // Change preset if needed (monitoring always uses .hd1920x1080)
      let targetPreset: AVCaptureSession.Preset =
        width > 1280 ? .hd1920x1080 : width > 640 ? .hd1280x720 : .medium
      if session.sessionPreset != targetPreset { session.sessionPreset = targetPreset }

      // Add streaming video output
      guard session.canAddOutput(output) else {
        logger.error("Failed to add video output when reusing capture session")
        session.commitConfiguration()
        return false
      }
      session.addOutput(output)

      if microphoneEnabled {
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
        audioOut.setSampleBufferDelegate(audioDelegate, queue: audioQueue)
        if session.canAddOutput(audioOut) {
          session.addOutput(audioOut)
          self.audioOutput = audioOut
          self.audioCaptureDelegate = audioDelegate
        } else {
          logger.warning(
            "Failed to add audio output to reused capture session — streaming without audio")
        }
      }

      session.commitConfiguration()
      // Session is already running — no startRunning() needed
    } else {
      // Cold start — create a new AVCaptureSession from scratch
      session = AVCaptureSession()
      session.enableMultitaskingCameraIfSupported()
      session.sessionPreset = width > 1280 ? .hd1920x1080 : width > 640 ? .hd1280x720 : .medium

      do {
        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) { session.addInput(input) }
      } catch {
        logger.error("Camera input error: \(error)")
        return false
      }

      if session.canAddOutput(output) {
        session.addOutput(output)
      } else {
        logger.error("Failed to add video output to capture session")
        return false
      }

      // Add microphone input for audio capture
      if microphoneEnabled, let mic = AVCaptureDevice.default(for: .audio),
        let micInput = try? AVCaptureDeviceInput(device: mic),
        session.canAddInput(micInput)
      {
        session.addInput(micInput)

        let audioOut = AVCaptureAudioDataOutput()
        let audioDelegate = AudioCaptureDelegate { [weak self] sampleBuffer in
          self?.handleAudioSampleBuffer(sampleBuffer)
        }
        audioOut.setSampleBufferDelegate(audioDelegate, queue: audioQueue)
        if session.canAddOutput(audioOut) {
          session.addOutput(audioOut)
          self.audioOutput = audioOut
          self.audioCaptureDelegate = audioDelegate
          logger.debug("Microphone audio capture added to session")
        }
      } else if !microphoneEnabled {
        logger.info("Microphone disabled by user — streaming without audio")
      } else {
        logger.error("Failed to add microphone input")
      }

      captureQueue.async { [weak self] in
        session.startRunning()
        self?.logger.debug("Capture session running: \(session.isRunning)")
      }
    }

    // Rotate output to match device orientation.
    if let connection = output.connection(with: .video) {
      if #available(iOS 17.0, macOS 14.0, *) {
        if connection.isVideoRotationAngleSupported(CGFloat(rotationAngle)) {
          connection.videoRotationAngle = CGFloat(rotationAngle)
        }
      } else {
        let orientation = videoOrientation(from: rotationAngle)
        if connection.isVideoOrientationSupported {
          connection.videoOrientation = orientation
        }
      }
    }

    self.captureSession = session
    self.videoOutput = output
    self.videoCaptureDelegate = delegate
    observeCaptureInterruptions(session)

    // Pre-create the audio encoder so it's ready when mic samples arrive.
    // Without this, audio samples arriving before the audio UDP is ready are silently dropped.
    if microphoneEnabled, self.audioConverter == nil {
      self.setupAudioEncoder()
    }
    return true
  }

  /// Observe AVCaptureSession interruption notifications so we can automatically
  /// resume the capture session when the interruption ends (e.g. returning from
  /// iPad split screen on iOS 15 where multitasking camera access is unavailable).
  private func observeCaptureInterruptions(_ session: AVCaptureSession) {
    removeInterruptionObservers()
    let nc = NotificationCenter.default
    let queue = OperationQueue()
    queue.underlyingQueue = captureQueue
    interruptionObservers.append(
      nc.addObserver(
        forName: .AVCaptureSessionWasInterrupted, object: session, queue: queue
      ) { [weak self] notification in
        guard let self else { return }
        if let reason = AVCaptureSession.interruptionReason(from: notification) {
          self.logger.warning("Capture session interrupted (reason \(reason))")
        } else {
          self.logger.warning("Capture session interrupted")
        }
      })
    interruptionObservers.append(
      nc.addObserver(
        forName: .AVCaptureSessionInterruptionEnded, object: session, queue: queue
      ) { [weak self] _ in
        guard let self else { return }
        guard !session.isRunning else { return }
        self.logger.info("Capture interruption ended — resuming session")
        session.startRunning()
      })
  }

  private func removeInterruptionObservers() {
    for observer in interruptionObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    interruptionObservers.removeAll()
  }

  // MARK: - H.264 Compression

  /// Box holding a weak reference to the session, used as the VTCompressionSession refcon.
  /// The box is retained for the lifetime of the compression session, but the weak reference
  /// safely becomes nil if the CameraStreamSession is deallocated first.
  private final class RefconBox {
    weak var session: CameraStreamSession?
    init(_ session: CameraStreamSession) { self.session = session }
  }

  /// Retains the refcon box so it stays alive as long as the compression session.
  /// Released when the compression session is invalidated.
  private var refconBox: RefconBox?

  private func setupCompression(width: Int, height: Int, fps: Int, bitrate: Int) {
    let box = RefconBox(self)
    let refcon = Unmanaged.passRetained(box).toOpaque()
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: nil,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: Self.compressionOutputCallback,
      refcon: refcon,
      compressionSessionOut: &session
    )

    guard status == noErr, let cs = session else {
      // Release the retained box since no compression session was created.
      Unmanaged<RefconBox>.fromOpaque(refcon).release()
      logger.error("VTCompressionSession create failed: \(status)")
      return
    }
    self.refconBox = box

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

    // Periodically cache a CGImage for snapshot requests while streaming.
    // JPEG encoding is deferred to when HomeKit actually requests a snapshot.
    // Dispatched to a utility queue so the pixel-copy + downscale doesn't block
    // captureQueue and cause frame drops. CVPixelBuffer supports concurrent
    // read-only locks, so this is safe alongside VTCompressionSessionEncodeFrame.
    snapshotFrameCounter += 1
    if snapshotFrameCounter >= snapshotInterval, let callback = onSnapshotFrame {
      snapshotFrameCounter = 0
      nonisolated(unsafe) let buffer = pixelBuffer
      DispatchQueue.global(qos: .utility).async {
        if let owned = MonitoringCaptureSession.copyFrameFromPixelBuffer(buffer) {
          callback(owned)
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
      sourceFrameRefcon: nil,
      infoFlagsOut: &flags
    )
    if status != noErr {
      logger.error("VTCompressionSessionEncodeFrame failed: \(status)")
    }
  }

  /// VTCompressionSession output callback — called by the encoder for each compressed frame.
  /// Uses a session-level callback instead of per-frame outputHandler closures to avoid
  /// accumulating heap-allocated closure contexts that cause recursive deallocation
  /// (stack overflow) when the session is invalidated after long-running capture.
  private static let compressionOutputCallback: VTCompressionOutputCallback = {
    refcon, _, status, _, sampleBuffer in
    guard let refcon else { return }
    let box = Unmanaged<RefconBox>.fromOpaque(refcon).takeUnretainedValue()
    guard let session = box.session else { return }
    autoreleasepool {
      if status != noErr {
        session.logger.error("Encode output error: \(status)")
        return
      }
      guard let sampleBuffer else { return }
      // CMSampleBuffer is a CFType (refcounted, immutable after creation). The
      // closure below retains it, so it stays alive until the async block completes.
      // nonisolated(unsafe) suppresses the Sendable warning — a Sendable wrapper
      // would add overhead with no safety benefit since the buffer is only read.
      nonisolated(unsafe) let buffer = sampleBuffer
      session.rtpQueue.async {
        session.processEncodedFrame(buffer)
      }
    }
  }

  // MARK: - RTP Packetization

  private func processEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
    dispatchPrecondition(condition: .onQueue(rtpQueue))
    guard let dataBuffer = sampleBuffer.dataBuffer else { return }

    // Derive RTP timestamp from the actual presentation timestamp (90kHz clock).
    // Using real PTS instead of a fixed-increment counter ensures the RTCP SR's
    // NTP↔RTP mapping stays accurate even when frames are dropped by
    // alwaysDiscardsLateVideoFrames — preventing receiver jitter buffer corrections
    // that cause visible hitches every 5 seconds.
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if !firstPTS.isValid { firstPTS = pts }
    let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS))
    rtpTimestamp = UInt32(truncatingIfNeeded: Int64(elapsed * 90000))

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

    lastSentRTPTimestamp = rtpTimestamp
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
      let fuIndicator: UInt8 = nri | 28  // Type 28 = FU-A

      // bodyStart/bodyEnd define the NAL body (everything after the header byte).
      let bodyStart = nal.startIndex + 1
      let bodyEnd = nal.endIndex
      var pos = bodyStart

      while pos < bodyEnd {
        let remaining = bodyEnd - pos
        let chunkSize = min(maxPayload - 2, remaining)  // -2 for FU indicator + FU header
        let isFirst = (pos == bodyStart)
        let isLast = (chunkSize == remaining)

        var fuHeader: UInt8 = nalType
        if isFirst { fuHeader |= 0x80 }  // Start bit
        if isLast { fuHeader |= 0x40 }  // End bit

        writeRTPHeader(marker: isLast && marker, payloadSize: 2 + chunkSize)
        rtpBuffer.append(fuIndicator)
        rtpBuffer.append(fuHeader)
        rtpBuffer.append(nal[pos..<pos + chunkSize])
        encryptAndSendVideo(payloadSize: 2 + chunkSize)

        pos += chunkSize
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
    Self.writeRTPHeader(
      into: &rtpBuffer, marker: marker, payloadType: rtpPayloadType,
      sequenceNumber: sequenceNumber, timestamp: rtpTimestamp, ssrc: videoSSRC,
      payloadSize: payloadSize)
    sequenceNumber &+= 1
  }

  /// Write a 12-byte RTP header (RFC 3550) into the given buffer, resetting and reserving space.
  nonisolated static func writeRTPHeader(
    into buffer: inout Data, marker: Bool, payloadType: UInt8,
    sequenceNumber: UInt16, timestamp: UInt32, ssrc: UInt32,
    payloadSize: Int
  ) {
    buffer.count = 0
    buffer.reserveCapacity(12 + payloadSize)
    buffer.append(0x80)  // V=2, P=0, X=0, CC=0
    buffer.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
    buffer.appendBigEndian(sequenceNumber)
    buffer.appendBigEndian(timestamp)
    buffer.appendBigEndian(ssrc)
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
    let sent = Self.sendUDP(data, fd: videoSocketFD, addr: &addr)
    if sent < 0 {
      let err = errno
      logger.debug("Video sendto failed: errno \(err) (\(data.count) bytes)")
    }
  }

  /// Send a UDP datagram via a BSD socket to the given address.
  /// Returns the number of bytes sent, or -1 on error (errno is set).
  @discardableResult
  nonisolated static func sendUDP(_ data: Data, fd: Int32, addr: inout sockaddr_in) -> Int {
    data.withUnsafeBytes { buf -> Int in
      guard let base = buf.baseAddress else { return -1 }
      return withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
          sendto(fd, base, buf.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
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
