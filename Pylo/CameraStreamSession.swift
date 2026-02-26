import AVFoundation
import AudioToolbox
import CoreImage
import Foundation
import VideoToolbox
import os

// MARK: - Camera Stream Session

/// Holds all state for a single streaming session: addresses, ports, SRTP keys, and the
/// video capture + RTP pipeline.
final class CameraStreamSession {

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

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "CameraStream")

  // Video pipeline
  private var captureSession: AVCaptureSession?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var compressionSession: VTCompressionSession?
  private let captureQueue = DispatchQueue(label: "me.fausak.taylor.Pylo.camera.capture")
  private let rtpQueue = DispatchQueue(label: "me.fausak.taylor.Pylo.camera.rtp")

  // Video UDP — BSD socket (immune to ICMP route-poisoning that kills NWConnection)
  private var videoSocketFD: Int32 = -1
  private var controllerVideoAddr: sockaddr_in?

  // RTP state
  private var sequenceNumber: UInt16 = 0
  private var rtpTimestamp: UInt32 = 0
  private var frameCount: Int = 0
  private var packetsSent: Int = 0
  private var octetsSent: Int = 0
  private var targetFPS: Int = 30
  private var rtpPayloadType: UInt8 = 99

  // SRTP state
  private var srtpContext: SRTPContext?

  // RTCP timer
  private var rtcpTimer: DispatchSourceTimer?

  // Audio pipeline (microphone → controller)
  private var audioOutput: AVCaptureAudioDataOutput?
  private var audioConverter: AudioConverterRef?
  private var audioSRTPContext: SRTPContext?
  private var audioRTPSeq: UInt16 = 0
  private var audioRTPTimestamp: UInt32 = 0
  private var audioPayloadType: UInt8 = 110
  private var audioPacketsSent: Int = 0
  private var audioOctetsSent: Int = 0
  private var audioRTCPTimer: DispatchSourceTimer?
  // Audio flags — written from the server queue, read from captureQueue/rtpQueue.
  private struct AudioFlags {
    var isMuted: Bool = false
    var speakerMuted: Bool = false
    var speakerVolume: Int = 100
  }
  private let audioFlags = OSAllocatedUnfairLock(initialState: AudioFlags())

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
  private var audioSocketFD: Int32 = -1
  private var audioReadSource: DispatchSourceRead?
  private var controllerAudioAddr: sockaddr_in?

  // Audio pipeline (controller → speaker)
  private var audioDecoder: AudioConverterRef?
  private var audioEngine: AVAudioEngine?
  private var audioPlayerNode: AVAudioPlayerNode?
  private var audioPlayerStarted: Bool = false
  private var incomingSRTPContext: SRTPContext?

  // Delegate retention — stored as properties instead of ObjC associated objects
  private var videoCaptureDelegate: VideoCaptureDelegate?
  private var audioCaptureDelegate: AudioCaptureDelegate?

  // Snapshot caching — periodically grab a JPEG from the video stream
  var onSnapshotFrame: ((Data) -> Void)?
  private var snapshotFrameCounter = 0
  private let snapshotInterval = 150  // every ~5s at 30fps
  private lazy var snapshotCIContext = CIContext()

  // Audio encoder state — accumulates PCM until we have a full AAC-ELD frame
  private var pcmAccumulator = Data()
  private let aacFrameSamples = 480  // AAC-ELD frame size at 16kHz

  init(
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

  func startStreaming(
    width: Int, height: Int, fps: Int, bitrate: Int, payloadType: UInt8,
    audioPayloadType: UInt8 = 110, camera: AVCaptureDevice, rotationAngle: Int = 90,
    swapDimensions: Bool = true
  ) {
    logger.info(
      "Starting stream: \(width)x\(height)@\(fps)fps, \(bitrate)kbps, PT=\(payloadType) → \(self.controllerAddress):\(self.controllerVideoPort)"
    )
    logger.info(
      "SRTP key=\(self.videoSRTPKey.count)B salt=\(self.videoSRTPSalt.count)B SSRC=\(self.videoSSRC)"
    )

    self.targetFPS = fps
    self.rtpPayloadType = payloadType
    self.audioPayloadType = audioPayloadType
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
      return
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
      return
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
      width: width, height: height, fps: fps, camera: camera, rotationAngle: rotationAngle)
    self.startRTCPTimer()

    // Audio: single BSD UDP socket for both send and receive.
    // Avoids NWConnection port conflicts and ICMP route-poisoning issues.
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else {
      logger.error("Failed to create audio UDP socket: errno \(errno)")
      return
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
      return
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
      // Socket will be closed in stopStreaming
    }
    readSource.resume()
    self.audioReadSource = readSource

    if self.audioConverter == nil {
      self.setupAudioEncoder()
    }
    self.startAudioRTCPTimer()
    self.setupAudioDecoder()
    self.setupAudioPlayback()
  }

  func stopStreaming() {
    logger.info("Stopping stream")

    // Video cleanup
    rtcpTimer?.cancel()
    rtcpTimer = nil

    // stopRunning() is synchronous — it blocks until the session fully
    // stops delivering frames. Calling it directly (rather than async)
    // ensures the VTCompressionSession won't receive new frames after
    // we invalidate it below.
    captureSession?.stopRunning()
    captureSession = nil

    if let cs = compressionSession {
      // Flush in-flight async encodes before invalidating (undefined behavior otherwise)
      VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: .positiveInfinity)
      VTCompressionSessionInvalidate(cs)
    }
    compressionSession = nil

    // Audio mic cleanup
    audioRTCPTimer?.cancel()
    audioRTCPTimer = nil
    audioOutput = nil

    if let enc = audioConverter {
      AudioConverterDispose(enc)
    }
    audioConverter = nil
    pcmAccumulator = Data()

    // Capture references to resources before nil-ing, then clean up
    // on rtpQueue to avoid data races with in-flight send/receive handlers.
    let readSource = audioReadSource
    let audioFD = audioSocketFD
    let videoFD = videoSocketFD
    let decoder = audioDecoder
    let player = audioPlayerNode
    let engine = audioEngine
    let incomingSRTP = incomingSRTPContext

    audioReadSource = nil
    readSource?.cancel()

    rtpQueue.sync {
      // By the time this executes, the cancelled read source and any
      // in-flight sendVideoUDP/sendAudioUDP/readAudioSocket calls have drained.
      if videoFD >= 0 { close(videoFD) }
      if audioFD >= 0 { close(audioFD) }
      player?.stop()
      engine?.stop()
      if let dec = decoder { AudioConverterDispose(dec) }
      _ = incomingSRTP  // prevent premature dealloc until after queue drains
    }

    // Now safe to nil out the remaining state (no concurrent access possible)
    videoSocketFD = -1
    controllerVideoAddr = nil
    srtpContext = nil
    audioSocketFD = -1
    controllerAudioAddr = nil
    audioSRTPContext = nil
    audioSampleCount = 0
    incomingAudioPacketCount = 0
    audioPlayerNode = nil
    audioPlayerStarted = false
    audioEngine = nil
    audioDecoder = nil
    incomingSRTPContext = nil
  }

  // MARK: - Video Capture

  private func setupCapture(
    width: Int, height: Int, fps: Int, camera: AVCaptureDevice, rotationAngle: Int = 90
  ) {
    do {
      try camera.lockForConfiguration()
      // Find closest frame rate range
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
    session.sessionPreset = width > 1280 ? .hd1920x1080 : width > 640 ? .hd1280x720 : .medium

    do {
      let input = try AVCaptureDeviceInput(device: camera)
      if session.canAddInput(input) { session.addInput(input) }
    } catch {
      logger.error("Camera input error: \(error)")
      return
    }

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    output.alwaysDiscardsLateVideoFrames = true
    let delegate = VideoCaptureDelegate { [weak self] pixelBuffer, pts in
      self?.encodeFrame(pixelBuffer, pts: pts)
    }
    output.setSampleBufferDelegate(delegate, queue: captureQueue)
    if session.canAddOutput(output) { session.addOutput(output) }

    // Rotate output to match device orientation.
    if let connection = output.connection(with: .video),
      connection.isVideoRotationAngleSupported(CGFloat(rotationAngle))
    {
      connection.videoRotationAngle = CGFloat(rotationAngle)
    }

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

    self.captureSession = session
    self.videoOutput = output
    self.videoCaptureDelegate = delegate

    // Pre-create the audio encoder so it's ready when mic samples arrive.
    // Without this, audio samples arriving before the audio UDP is ready are silently dropped.
    if self.audioConverter == nil {
      self.setupAudioEncoder()
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      session.startRunning()
      self?.logger.info("Capture session running: \(session.isRunning)")
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
    // Data rate limit: allow bursts up to 1.5x average per second
    let bytesPerSecond = (bitrate * 1000 / 8) as CFNumber
    let one = 1.0 as CFNumber
    VTSessionSetProperty(
      cs, key: kVTCompressionPropertyKey_DataRateLimits,
      value: [bytesPerSecond, one] as CFArray)

    VTCompressionSessionPrepareToEncodeFrames(cs)
    self.compressionSession = cs
  }

  private func encodeFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    guard let cs = compressionSession else { return }

    frameCount += 1

    // Periodically cache a JPEG for snapshot requests while streaming.
    snapshotFrameCounter += 1
    if snapshotFrameCounter >= snapshotInterval, let callback = onSnapshotFrame {
      snapshotFrameCounter = 0
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let jpeg = snapshotCIContext.jpegRepresentation(
          of: ciImage, colorSpace: colorSpace, options: [:])
      {
        callback(jpeg)
      }
    }

    // Force keyframe on first frame
    let props: CFDictionary? =
      frameCount == 1
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
        if status != noErr {
          self?.logger.error("Encode output error: \(status)")
          return
        }
        guard let sampleBuffer, let self else { return }
        self.rtpQueue.async {
          self.processEncodedFrame(sampleBuffer)
        }
      }
    )
    if status != noErr {
      logger.error("VTCompressionSessionEncodeFrame failed: \(status)")
    }
  }

  // MARK: - RTP Packetization

  private func processEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
    guard let dataBuffer = sampleBuffer.dataBuffer else { return }

    // Get H.264 NAL units from the sample buffer
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(
      dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard let ptr = dataPointer, totalLength > 0 else { return }

    let data = Data(bytes: ptr, count: totalLength)

    // Check for keyframe — if so, send SPS/PPS first
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    if isKeyframe || frameCount % 300 == 1 {
      logger.debug("Frame \(self.frameCount) encoded: \(totalLength) bytes, keyframe=\(isKeyframe)")
    }

    if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
      sendParameterSets(formatDesc)
    }

    // Parse AVCC-format NAL units (4-byte length prefix)
    // First pass: collect non-SEI NAL units
    var nalUnits: [Data] = []
    var offset = 0
    var nalIndex = 0
    while offset + 4 <= data.count {
      let nalLength =
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8
        | Int(data[offset + 3])
      offset += 4
      guard nalLength > 0, offset + nalLength <= data.count else { break }

      let nalUnit = data[offset..<offset + nalLength]
      _ = nalUnit[nalUnit.startIndex] & 0x1F

      nalUnits.append(Data(nalUnit))
      offset += nalLength
      nalIndex += 1
    }

    // Second pass: send with correct marker bits
    for (i, nal) in nalUnits.enumerated() {
      let isLast = (i == nalUnits.count - 1)
      sendNALUnit(nal, marker: isLast)
    }

    // Advance RTP timestamp (90kHz clock)
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

        var payload = Data([fuIndicator, fuHeader])
        payload.append(nal[(nal.startIndex + offset)..<(nal.startIndex + offset + chunkSize)])
        // Only set marker on the last fragment AND only if this is the last NAL of the access unit
        sendRTPPacket(payload: payload, marker: isLast && marker)

        offset += chunkSize
      }
    }
  }

  private func sendRTPPacket(payload: Data, marker: Bool) {
    // RTP header (12 bytes) per RFC 3550
    var header = Data(count: 12)
    header[0] = 0x80  // V=2, P=0, X=0, CC=0
    header[1] = (marker ? 0x80 : 0x00) | (rtpPayloadType & 0x7F)  // M bit + dynamic PT
    header[2] = UInt8(sequenceNumber >> 8)
    header[3] = UInt8(sequenceNumber & 0xFF)
    header[4] = UInt8((rtpTimestamp >> 24) & 0xFF)
    header[5] = UInt8((rtpTimestamp >> 16) & 0xFF)
    header[6] = UInt8((rtpTimestamp >> 8) & 0xFF)
    header[7] = UInt8(rtpTimestamp & 0xFF)
    header[8] = UInt8((videoSSRC >> 24) & 0xFF)
    header[9] = UInt8((videoSSRC >> 16) & 0xFF)
    header[10] = UInt8((videoSSRC >> 8) & 0xFF)
    header[11] = UInt8(videoSSRC & 0xFF)

    sequenceNumber &+= 1

    var rtpPacket = header
    rtpPacket.append(payload)

    // Encrypt with SRTP
    if let ctx = srtpContext {
      rtpPacket = ctx.protect(rtpPacket)
    }

    // Send via BSD UDP socket
    packetsSent += 1
    octetsSent += payload.count
    sendVideoUDP(rtpPacket)
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
    guard let ctx = srtpContext else { return }

    let sr = Self.buildRTCPSenderReport(
      ssrc: videoSSRC, rtpTimestamp: rtpTimestamp,
      packetsSent: packetsSent, octetsSent: octetsSent)
    let srtcpPacket = ctx.protectRTCP(sr)
    sendVideoUDP(srtcpPacket)
    logger.debug(
      "Sent RTCP-SR: packets=\(self.packetsSent) octets=\(self.octetsSent)")
  }

  // MARK: - Audio Encoder (PCM → AAC-ELD)

  private func setupAudioEncoder() {
    // Input: Linear PCM Float32, 16kHz, mono
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

    // Output: AAC-ELD, 16kHz, mono
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
      logger.error("AudioConverter (encoder) create failed: \(status)")
      return
    }

    // Set bitrate to 24kbps (good quality for voice)
    var bitrate: UInt32 = 24000
    AudioConverterSetProperty(
      converter, kAudioConverterEncodeBitRate,
      UInt32(MemoryLayout<UInt32>.size), &bitrate)

    self.audioConverter = converter
    logger.info("AAC-ELD encoder created (16kHz mono → AAC-ELD)")
  }

  // MARK: - Audio Sample Buffer Processing

  private var audioSampleCount: Int = 0

  private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard audioConverter != nil else { return }
    guard audioSocketFD >= 0 else { return }
    guard !isMuted else { return }
    audioSampleCount += 1

    // Get PCM data from the sample buffer
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(
      blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard let ptr = dataPointer, totalLength > 0 else { return }

    // Get the source format to know what we're dealing with
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee

    let rawData = Data(bytes: ptr, count: totalLength)

    // Convert to Float32 at 16kHz if needed (the mic may deliver Int16 at 44.1/48kHz)
    let pcmFloat32: Data
    if let asbd, asbd.mFormatID == kAudioFormatLinearPCM {
      pcmFloat32 = convertToFloat32At16kHz(rawData, sourceASBD: asbd)
    } else {
      logger.warning("Audio: unexpected format ID \(asbd?.mFormatID ?? 0)")
      return
    }

    // Accumulate PCM and encode when we have enough for an AAC-ELD frame
    pcmAccumulator.append(pcmFloat32)
    let frameSizeBytes = aacFrameSamples * 4  // 480 samples * 4 bytes/sample (Float32)

    while pcmAccumulator.count >= frameSizeBytes {
      let frameData = pcmAccumulator.prefix(frameSizeBytes)
      pcmAccumulator = Data(pcmAccumulator.dropFirst(frameSizeBytes))
      encodeAndSendAudioFrame(Data(frameData))
    }
  }

  /// Convert PCM audio data to Float32 at 16kHz mono.
  private func convertToFloat32At16kHz(
    _ data: Data, sourceASBD: AudioStreamBasicDescription
  ) -> Data {
    let sourceSampleRate = sourceASBD.mSampleRate
    let sourceChannels = Int(sourceASBD.mChannelsPerFrame)
    let isFloat = (sourceASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let is16Bit = sourceASBD.mBitsPerChannel == 16
    let bytesPerSample = Int(sourceASBD.mBitsPerChannel / 8)

    // First convert to Float32 mono
    var floatSamples: [Float] = []

    if isFloat && bytesPerSample == 4 {
      // Already Float32
      data.withUnsafeBytes { ptr in
        let floatPtr = ptr.bindMemory(to: Float.self)
        if sourceChannels == 1 {
          floatSamples = Array(floatPtr)
        } else {
          // Mix down to mono by averaging all channels
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
      // Int16 → Float32, mix down to mono if multi-channel
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

  /// Encode a single AAC-ELD frame (480 samples) and send as an RTP packet.
  private func encodeAndSendAudioFrame(_ pcmData: Data) {
    guard let converter = audioConverter else { return }

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

    // Use withUnsafeBytes to keep the PCM pointer alive through the entire converter call
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
          { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
            guard let userData = inUserData else {
              ioNumberDataPackets.pointee = 0
              return noErr
            }
            let cb = userData.assumingMemoryBound(to: AudioEncoderInput.self)

            if cb.pointee.consumed {
              ioNumberDataPackets.pointee = 0
              return noErr  // Signal "no more data" without error
            }
            cb.pointee.consumed = true

            ioNumberDataPackets.pointee = UInt32(cb.pointee.srcSize / 4)  // Float32 samples
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
    guard encodedSize > 0 else { return }
    let aacData = Data(bytes: outputBuffer, count: encodedSize)

    // Wrap in RFC 3640 AU header section (HomeKit expects this framing)
    let framedPayload = AUHeader.add(to: aacData)

    sendAudioRTPPacket(payload: framedPayload)
  }

  // MARK: - Audio RTP Send

  private func sendAudioRTPPacket(payload: Data) {
    // Build 12-byte RTP header
    var header = Data(count: 12)
    header[0] = 0x80  // V=2
    header[1] = 0x80 | (audioPayloadType & 0x7F)  // M=1 (every AAC frame is a complete AU)
    header[2] = UInt8(audioRTPSeq >> 8)
    header[3] = UInt8(audioRTPSeq & 0xFF)
    header[4] = UInt8((audioRTPTimestamp >> 24) & 0xFF)
    header[5] = UInt8((audioRTPTimestamp >> 16) & 0xFF)
    header[6] = UInt8((audioRTPTimestamp >> 8) & 0xFF)
    header[7] = UInt8(audioRTPTimestamp & 0xFF)
    header[8] = UInt8((audioSSRC >> 24) & 0xFF)
    header[9] = UInt8((audioSSRC >> 16) & 0xFF)
    header[10] = UInt8((audioSSRC >> 8) & 0xFF)
    header[11] = UInt8(audioSSRC & 0xFF)

    audioRTPSeq &+= 1
    audioRTPTimestamp &+= UInt32(aacFrameSamples)  // 480 samples at 16kHz clock

    var rtpPacket = header
    rtpPacket.append(payload)

    // SRTP protect with audio context
    if let ctx = audioSRTPContext {
      rtpPacket = ctx.protect(rtpPacket)
    }

    audioPacketsSent += 1
    audioOctetsSent += payload.count
    sendAudioUDP(rtpPacket)
  }

  // MARK: - Audio RTCP Sender Report

  private func startAudioRTCPTimer() {
    let timer = DispatchSource.makeTimerSource(queue: rtpQueue)
    timer.schedule(deadline: .now() + 1.0, repeating: 5.0)
    timer.setEventHandler { [weak self] in
      self?.sendAudioRTCPSenderReport()
    }
    timer.resume()
    self.audioRTCPTimer = timer
  }

  private func sendAudioRTCPSenderReport() {
    guard let ctx = audioSRTPContext else { return }

    let sr = Self.buildRTCPSenderReport(
      ssrc: audioSSRC, rtpTimestamp: audioRTPTimestamp,
      packetsSent: audioPacketsSent, octetsSent: audioOctetsSent)
    let srtcpPacket = ctx.protectRTCP(sr)
    sendAudioUDP(srtcpPacket)
    logger.debug(
      "Sent audio RTCP-SR: packets=\(self.audioPacketsSent) octets=\(self.audioOctetsSent)"
    )
  }

  // MARK: - Audio Decoder (AAC-ELD → PCM)

  private func setupAudioDecoder() {
    // Input: AAC-ELD, 16kHz, mono
    var inputDesc = AudioStreamBasicDescription(
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

    // Output: Linear PCM Float32, 16kHz, mono
    var outputDesc = AudioStreamBasicDescription(
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

    var decoder: AudioConverterRef?
    let status = AudioConverterNew(&inputDesc, &outputDesc, &decoder)
    if status != noErr {
      logger.error("AudioConverter (decoder) create failed: \(status)")
      return
    }

    self.audioDecoder = decoder
    logger.info("AAC-ELD decoder created")
  }

  // MARK: - Audio Playback (AVAudioEngine)

  private func setupAudioPlayback() {
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()

    engine.attach(playerNode)

    // Connect player to main mixer with Float32/16kHz/mono format
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    else {
      logger.error("Failed to create audio format for playback")
      return
    }
    engine.connect(playerNode, to: engine.mainMixerNode, format: format)

    // Don't start the engine here — the capture session starts asynchronously
    // and will interrupt the audio session, killing the engine. Instead, we
    // start it lazily in ensureAudioEngineRunning() when we actually have
    // audio to play.
    self.audioEngine = engine
    self.audioPlayerNode = playerNode
    self.audioPlayerStarted = false
    logger.info("Audio playback engine prepared (will start on first audio)")
  }

  /// Ensure the AVAudioEngine is running. Call before scheduling buffers.
  /// The engine may have been interrupted by the capture session or audio route changes.
  private func ensureAudioEngineRunning() -> Bool {
    guard let engine = audioEngine else { return false }
    if engine.isRunning { return true }
    do {
      try engine.start()
      logger.info("AVAudioEngine started")
      return true
    } catch {
      logger.error("AVAudioEngine start error: \(error)")
      return false
    }
  }

  // MARK: - Audio BSD Socket Send/Receive

  /// Send data via the BSD audio socket to the controller's audio port.
  private func sendAudioUDP(_ data: Data) {
    guard audioSocketFD >= 0, var addr = controllerAudioAddr else { return }
    data.withUnsafeBytes { buf in
      guard let base = buf.baseAddress else { return }
      withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
          _ = sendto(
            audioSocketFD, base, buf.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
  }

  /// Called by GCD read source when data is available on the audio socket.
  private func readAudioSocket() {
    var buf = [UInt8](repeating: 0, count: 2048)
    while true {
      let n = recv(audioSocketFD, &buf, buf.count, 0)
      if n <= 0 { break }  // EAGAIN (no more data) or error
      // Distinguish RTP from RTCP: RTCP has payload type 200-204 in byte[1]
      // (RFC 5761). We only process RTP audio; RTCP receiver reports are ignored.
      guard n >= 12 else { continue }
      let pt = buf[1]
      if pt >= 200 && pt <= 204 {
        // SRTCP packet from controller (receiver report, etc.) — skip
        continue
      }
      let data = Data(buf[0..<n])
      handleIncomingAudioPacket(data)
    }
  }

  private var incomingAudioPacketCount: Int = 0

  private func handleIncomingAudioPacket(_ srtpData: Data) {
    guard let ctx = incomingSRTPContext else { return }
    guard !speakerMuted else { return }
    incomingAudioPacketCount += 1

    // SRTP unprotect
    guard let rtpPacket = ctx.unprotect(srtpData) else {
      logger.warning(
        "Failed to unprotect incoming audio SRTP packet (#\(self.incomingAudioPacketCount))")
      return
    }

    // Extract AAC-ELD payload from RTP (skip 12-byte header)
    guard rtpPacket.count > 12 else { return }
    var aacPayload = Data(rtpPacket[rtpPacket.startIndex + 12..<rtpPacket.endIndex])
    guard !aacPayload.isEmpty else { return }

    // Strip RFC 3640 AU header section if present.
    aacPayload = AUHeader.strip(from: aacPayload)

    guard !aacPayload.isEmpty else { return }

    // Decode AAC-ELD → PCM
    guard let decoder = audioDecoder else { return }

    let outputSamples = aacFrameSamples
    let outputBufferSize = outputSamples * 4  // Float32
    let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputBufferSize)
    defer { outputBuffer.deallocate() }

    var outputBufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(outputBufferSize),
        mData: outputBuffer
      )
    )

    // For PCM output, mFramesPerPacket=1 so each "packet" is one sample.
    // Request a full frame's worth of samples (480) to decode the entire AAC-ELD frame.
    var packetCount: UInt32 = UInt32(outputSamples)

    let status: OSStatus = aacPayload.withUnsafeBytes { aacBuf -> OSStatus in
      guard let aacBase = aacBuf.baseAddress else { return -1 }

      var cbData = AudioDecoderInput(
        srcData: aacBase,
        srcSize: UInt32(aacPayload.count),
        packetDesc: AudioStreamPacketDescription(
          mStartOffset: 0,
          mVariableFramesInPacket: 0,
          mDataByteSize: UInt32(aacPayload.count)
        ),
        consumed: false
      )

      return withUnsafeMutablePointer(to: &cbData) { cbPtr in
        AudioConverterFillComplexBuffer(
          decoder,
          { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
            guard let userData = inUserData else {
              ioNumberDataPackets.pointee = 0
              return noErr
            }
            let cb = userData.assumingMemoryBound(to: AudioDecoderInput.self)

            if cb.pointee.consumed {
              ioNumberDataPackets.pointee = 0
              return noErr  // Signal "no more data" without error
            }
            cb.pointee.consumed = true
            ioNumberDataPackets.pointee = 1

            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: cb.pointee.srcData)
            ioData.pointee.mBuffers.mDataByteSize = cb.pointee.srcSize
            ioData.pointee.mBuffers.mNumberChannels = 1

            if let outDesc = outDataPacketDescription {
              let descOffset = MemoryLayout<AudioDecoderInput>.offset(of: \.packetDesc)!
              outDesc.pointee = userData.advanced(by: descOffset)
                .assumingMemoryBound(to: AudioStreamPacketDescription.self)
            }
            return noErr
          },
          cbPtr,
          &packetCount,
          &outputBufferList,
          nil
        )
      }
    }

    let decodedSize = Int(outputBufferList.mBuffers.mDataByteSize)
    if status != noErr && decodedSize == 0 { return }
    guard decodedSize > 0, let playerNode = audioPlayerNode else { return }

    let sampleCount = decodedSize / 4

    // Skip tiny priming buffers (< 10 samples / 0.6ms) — they're inaudible and
    // can cause the player to enter a finished state before real audio arrives.
    if sampleCount < 10 { return }

    let gain = Float(speakerVolume) / 100.0

    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
      let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))
    else {
      return
    }

    pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
    outputBuffer.withMemoryRebound(to: Float.self, capacity: sampleCount) { src in
      if let channelData = pcmBuffer.floatChannelData?[0] {
        for i in 0..<sampleCount {
          channelData[i] = src[i] * gain
        }
      }
    }

    guard ensureAudioEngineRunning() else { return }
    playerNode.scheduleBuffer(pcmBuffer)
    if !audioPlayerStarted || !playerNode.isPlaying {
      playerNode.play()
      audioPlayerStarted = true
    }
  }

  // MARK: - RTCP Sender Report Builder

  /// Builds a 28-byte RTCP Sender Report (RFC 3550 §6.4.1).
  static func buildRTCPSenderReport(
    ssrc: UInt32,
    rtpTimestamp: UInt32,
    packetsSent: Int,
    octetsSent: Int,
    now: Date = Date()
  ) -> Data {
    var sr = Data(count: 28)
    // Header: V=2, P=0, RC=0, PT=200 (SR), length=6
    sr[0] = 0x80
    sr[1] = 200
    sr[2] = 0x00
    sr[3] = 0x06
    // SSRC
    sr[4] = UInt8((ssrc >> 24) & 0xFF)
    sr[5] = UInt8((ssrc >> 16) & 0xFF)
    sr[6] = UInt8((ssrc >> 8) & 0xFF)
    sr[7] = UInt8(ssrc & 0xFF)
    // NTP timestamp (seconds since 1900-01-01)
    let ntpEpochOffset: TimeInterval = 2_208_988_800
    let ntpTime = now.timeIntervalSince1970 + ntpEpochOffset
    let ntpSec = UInt32(ntpTime)
    let ntpFrac = UInt32((ntpTime - Double(ntpSec)) * 4_294_967_296.0)
    sr[8] = UInt8((ntpSec >> 24) & 0xFF)
    sr[9] = UInt8((ntpSec >> 16) & 0xFF)
    sr[10] = UInt8((ntpSec >> 8) & 0xFF)
    sr[11] = UInt8(ntpSec & 0xFF)
    sr[12] = UInt8((ntpFrac >> 24) & 0xFF)
    sr[13] = UInt8((ntpFrac >> 16) & 0xFF)
    sr[14] = UInt8((ntpFrac >> 8) & 0xFF)
    sr[15] = UInt8(ntpFrac & 0xFF)
    // RTP timestamp
    sr[16] = UInt8((rtpTimestamp >> 24) & 0xFF)
    sr[17] = UInt8((rtpTimestamp >> 16) & 0xFF)
    sr[18] = UInt8((rtpTimestamp >> 8) & 0xFF)
    sr[19] = UInt8(rtpTimestamp & 0xFF)
    // Sender's packet count
    let pc = UInt32(packetsSent)
    sr[20] = UInt8((pc >> 24) & 0xFF)
    sr[21] = UInt8((pc >> 16) & 0xFF)
    sr[22] = UInt8((pc >> 8) & 0xFF)
    sr[23] = UInt8(pc & 0xFF)
    // Sender's octet count
    let oc = UInt32(octetsSent)
    sr[24] = UInt8((oc >> 24) & 0xFF)
    sr[25] = UInt8((oc >> 16) & 0xFF)
    sr[26] = UInt8((oc >> 8) & 0xFF)
    sr[27] = UInt8(oc & 0xFF)
    return sr
  }
}
// MARK: - Video Capture Delegate

private final class VideoCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
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

/// Helper for passing compressed audio data + packet description through the AudioConverter decoder C callback.
private struct AudioDecoderInput {
  var srcData: UnsafeRawPointer?
  var srcSize: UInt32
  var packetDesc: AudioStreamPacketDescription
  var consumed: Bool
}

// MARK: - Audio Capture Delegate

private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
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
