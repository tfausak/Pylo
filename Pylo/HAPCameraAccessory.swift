import AVFoundation
import AudioToolbox
import CommonCrypto
import CoreImage
import Foundation
import UIKit
import VideoToolbox
import os

// MARK: - Camera Accessory

/// HAP camera sub-accessory exposing CameraRTPStreamManagement.
/// Handles the full pipeline: TLV8 negotiation → video capture → H.264 → RTP → SRTP → UDP.
final class HAPCameraAccessory: HAPAccessoryProtocol {

  let aid: Int
  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: Any) -> Void)?

  /// Called before/after snapshot capture so the host can pause other capture sessions
  /// (e.g. the ambient light monitor) that would conflict with the snapshot session.
  var onSnapshotWillCapture: (() -> Void)?
  var onSnapshotDidCapture: (() -> Void)?

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Camera")

  /// Which camera to use for streaming and snapshots (nil = default back wide-angle).
  var selectedCameraID: String?

  /// Minimum bitrate (kbps) to use regardless of what the controller negotiates.
  var minimumBitrate: Int = 0

  /// Active streaming session (nil when idle).
  private var streamSession: CameraStreamSession?

  /// Most recent JPEG snapshot captured during streaming (used as fallback for snapshot requests).
  private var cachedSnapshot: Data?

  /// Whether the microphone is muted.
  private var isMuted: Bool = false

  /// Whether the speaker is muted.
  private var speakerMuted: Bool = false
  /// Speaker volume (0-100).
  private var speakerVolume: Int = 100

  // Pending setup endpoint response (written by controller, read back after)
  private var setupEndpointsResponse = Data()

  init(
    aid: Int,
    name: String = "Pylo Camera",
    model: String = "HAP-PoC",
    manufacturer: String = "DIY",
    serialNumber: String = "000000",
    firmwareRevision: String = "0.1.0"
  ) {
    self.aid = aid
    self.name = name
    self.model = model
    self.manufacturer = manufacturer
    self.serialNumber = serialNumber
    self.firmwareRevision = firmwareRevision
  }

  // MARK: - Instance IDs (iid)

  static let iidCameraService = 8
  static let iidSupportedVideoConfig = 9
  static let iidSupportedAudioConfig = 10
  static let iidSupportedRTPConfig = 11
  static let iidSetupEndpoints = 12
  static let iidSelectedRTPStreamConfig = 13
  static let iidStreamingStatus = 14
  static let iidMicrophoneService = 15
  static let iidMicrophoneMute = 16
  static let iidSpeakerService = 17
  static let iidSpeakerMute = 18
  static let iidSpeakerVolume = 19

  // MARK: - HAP UUIDs

  static let uuidCameraRTPStreamManagement = "110"
  static let uuidSupportedVideoStreamConfig = "114"
  static let uuidSupportedAudioStreamConfig = "115"
  static let uuidSupportedRTPConfig = "116"
  static let uuidSelectedRTPStreamConfig = "117"
  static let uuidSetupEndpoints = "118"
  static let uuidStreamingStatus = "120"
  static let uuidMicrophone = "112"
  static let uuidSpeaker = "113"
  static let uuidMute = "11A"
  static let uuidVolume = "119"

  // MARK: - Read Characteristic

  func readCharacteristic(iid: Int) -> Any? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return manufacturer
    case AccessoryInfoIID.model: return model
    case AccessoryInfoIID.name: return name
    case AccessoryInfoIID.serialNumber: return serialNumber
    case AccessoryInfoIID.firmwareRevision: return firmwareRevision
    case Self.iidSupportedVideoConfig:
      return Self.supportedVideoConfig().base64()
    case Self.iidSupportedAudioConfig:
      return Self.supportedAudioConfig().base64()
    case Self.iidSupportedRTPConfig:
      return Self.supportedRTPConfig().base64()
    case Self.iidSetupEndpoints:
      return setupEndpointsResponse.base64EncodedString()
    case Self.iidSelectedRTPStreamConfig:
      return ""  // write-only effectively
    case Self.iidStreamingStatus:
      return streamingStatusTLV().base64EncodedString()
    case Self.iidMicrophoneMute: return isMuted
    case Self.iidSpeakerMute: return speakerMuted
    case Self.iidSpeakerVolume: return speakerVolume
    default: return nil
    }
  }

  // MARK: - Write Characteristic

  @discardableResult
  func writeCharacteristic(iid: Int, value: Any) -> Bool {
    switch iid {
    case AccessoryInfoIID.identify:
      identify()
      return true
    case Self.iidSetupEndpoints:
      return handleSetupEndpoints(value)
    case Self.iidSelectedRTPStreamConfig:
      return handleSelectedRTPStreamConfig(value)
    case Self.iidMicrophoneMute:
      if let v = value as? Bool {
        isMuted = v
        streamSession?.isMuted = v
        return true
      }
      if let v = value as? Int {
        isMuted = v != 0
        streamSession?.isMuted = (v != 0)
        return true
      }
      return false
    case Self.iidSpeakerMute:
      if let v = value as? Bool {
        speakerMuted = v
        streamSession?.speakerMuted = v
        return true
      }
      if let v = value as? Int {
        speakerMuted = v != 0
        streamSession?.speakerMuted = (v != 0)
        return true
      }
      return false
    case Self.iidSpeakerVolume:
      if let v = value as? Int {
        speakerVolume = max(0, min(100, v))
        streamSession?.speakerVolume = speakerVolume
        return true
      }
      return false
    default:
      return false
    }
  }

  func identify() {
    logger.info("Camera identify requested")
  }

  // MARK: - Supported Configurations (static TLV8 blobs)

  /// SupportedVideoStreamConfiguration TLV8
  static func supportedVideoConfig() -> TLV8.Builder {
    // H.264 codec parameters: Constrained Baseline profile, Level 3.1
    var codecParams = TLV8.Builder()
    codecParams.add(0x01, byte: 0x00)  // ProfileID: Constrained Baseline
    codecParams.add(0x02, byte: 0x00)  // Level: 3.1
    codecParams.add(0x03, byte: 0x00)  // Packetization: Non-interleaved

    // Resolution: 1920x1080 @ 30fps
    var attrs1080 = TLV8.Builder()
    attrs1080.add(0x01, uint16: 1920)
    attrs1080.add(0x02, uint16: 1080)
    attrs1080.add(0x03, byte: 30)

    // Resolution: 1280x720 @ 30fps
    var attrs720 = TLV8.Builder()
    attrs720.add(0x01, uint16: 1280)
    attrs720.add(0x02, uint16: 720)
    attrs720.add(0x03, byte: 30)

    // Resolution: 320x240 @ 15fps
    var attrs240 = TLV8.Builder()
    attrs240.add(0x01, uint16: 320)
    attrs240.add(0x02, uint16: 240)
    attrs240.add(0x03, byte: 15)

    // Video codec config
    var codecConfig = TLV8.Builder()
    codecConfig.add(0x01, byte: 0x00)  // CodecType: H.264
    codecConfig.add(0x02, tlv: codecParams)
    codecConfig.add(0x03, tlv: attrs1080)
    codecConfig.add(0x03, tlv: attrs720)
    codecConfig.add(0x03, tlv: attrs240)

    // Top-level
    var config = TLV8.Builder()
    config.add(0x01, tlv: codecConfig)
    return config
  }

  /// SupportedAudioStreamConfiguration TLV8
  static func supportedAudioConfig() -> TLV8.Builder {
    // AAC-ELD codec params: 1 channel, variable bitrate, 16kHz
    var codecParams = TLV8.Builder()
    codecParams.add(0x01, byte: 1)  // Channels: 1
    codecParams.add(0x02, byte: 0)  // BitRate: Variable
    codecParams.add(0x03, byte: 1)  // SampleRate: 16kHz

    // Audio codec config
    var codecConfig = TLV8.Builder()
    codecConfig.add(0x01, byte: 2)  // CodecType: AAC-ELD
    codecConfig.add(0x02, tlv: codecParams)

    // Top-level
    var config = TLV8.Builder()
    config.add(0x01, tlv: codecConfig)
    config.add(0x02, byte: 0)  // ComfortNoiseSupport: No
    return config
  }

  /// SupportedRTPConfiguration TLV8
  static func supportedRTPConfig() -> TLV8.Builder {
    var config = TLV8.Builder()
    config.add(0x02, byte: 0x00)  // SRTP crypto: AES_CM_128_HMAC_SHA1_80
    return config
  }

  // MARK: - Streaming Status

  private func streamingStatusTLV() -> Data {
    var b = TLV8.Builder()
    let status: UInt8 = streamSession != nil ? 1 : 0  // 0=Available, 1=InUse, 2=Unavailable
    b.add(0x01, byte: status)
    return b.build()
  }

  // MARK: - Setup Endpoints

  private func handleSetupEndpoints(_ value: Any) -> Bool {
    guard let b64 = value as? String, let data = Data(base64Encoded: b64) else { return false }
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]

    var sessionID = Data()
    var controllerAddress = ""
    var controllerVideoPort: UInt16 = 0
    var controllerAudioPort: UInt16 = 0
    var videoSRTPKey = Data()
    var videoSRTPSalt = Data()
    var audioSRTPKey = Data()
    var audioSRTPSalt = Data()

    for (tag, val) in tlvs {
      switch tag {
      case 0x01: sessionID = val
      case 0x03:  // Controller address
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        for (stag, sval) in sub {
          switch stag {
          case 0x02: controllerAddress = String(data: sval, encoding: .utf8) ?? ""
          case 0x03:
            if sval.count >= 2 {
              controllerVideoPort =
                UInt16(sval[sval.startIndex]) | UInt16(sval[sval.startIndex + 1]) << 8
            }
          case 0x04:
            if sval.count >= 2 {
              controllerAudioPort =
                UInt16(sval[sval.startIndex]) | UInt16(sval[sval.startIndex + 1]) << 8
            }
          default: break
          }
        }
      case 0x04:  // Video SRTP params
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        for (stag, sval) in sub {
          switch stag {
          case 0x02: videoSRTPKey = sval
          case 0x03: videoSRTPSalt = sval
          default: break
          }
        }
      case 0x05:  // Audio SRTP params
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        for (stag, sval) in sub {
          switch stag {
          case 0x02: audioSRTPKey = sval
          case 0x03: audioSRTPSalt = sval
          default: break
          }
        }
      default: break
      }
    }

    logger.info(
      "SetupEndpoints: controller=\(controllerAddress):\(controllerVideoPort)/\(controllerAudioPort)"
    )

    let videoSSRC = UInt32.random(in: 1...UInt32.max)
    let audioSSRC = UInt32.random(in: 1...UInt32.max)

    // Determine local IP address — must be on the same subnet as the controller
    let localAddress = Self.localIPAddress(matching: controllerAddress) ?? "0.0.0.0"

    // Allocate UDP ports — video RTCP uses videoPort+1, so audio must start at +2
    let videoPort: UInt16 = UInt16.random(in: 50000...59998)
    let audioPort: UInt16 = videoPort + 2

    logger.info("SetupEndpoints response: local=\(localAddress):\(videoPort) SSRC=\(videoSSRC)")

    // Create the stream session — both sides use the SAME SRTP keys
    let session = CameraStreamSession(
      sessionID: sessionID,
      controllerAddress: controllerAddress,
      controllerVideoPort: controllerVideoPort,
      controllerAudioPort: controllerAudioPort,
      videoSRTPKey: videoSRTPKey,
      videoSRTPSalt: videoSRTPSalt,
      audioSRTPKey: audioSRTPKey,
      audioSRTPSalt: audioSRTPSalt,
      localAddress: localAddress,
      localVideoPort: videoPort,
      localAudioPort: audioPort,
      videoSSRC: videoSSRC,
      audioSSRC: audioSSRC
    )
    self.streamSession = session

    // Build response TLV8 — echo back the controller's SRTP keys
    // Both sides use the same shared key material
    var addrTLV = TLV8.Builder()
    addrTLV.add(0x01, byte: 0x00)  // IPv4
    addrTLV.add(0x02, Data(localAddress.utf8))
    addrTLV.add(0x03, uint16: videoPort)
    addrTLV.add(0x04, uint16: audioPort)

    var videoSRTPTLV = TLV8.Builder()
    videoSRTPTLV.add(0x01, byte: 0x00)  // AES_CM_128_HMAC_SHA1_80
    videoSRTPTLV.add(0x02, videoSRTPKey)
    videoSRTPTLV.add(0x03, videoSRTPSalt)

    var audioSRTPTLV = TLV8.Builder()
    audioSRTPTLV.add(0x01, byte: 0x00)
    audioSRTPTLV.add(0x02, audioSRTPKey)
    audioSRTPTLV.add(0x03, audioSRTPSalt)

    var response = TLV8.Builder()
    response.add(0x01, sessionID)
    response.add(0x02, byte: 0x00)  // Status: Success
    response.add(0x03, tlv: addrTLV)
    response.add(0x04, tlv: videoSRTPTLV)
    response.add(0x05, tlv: audioSRTPTLV)
    response.add(0x06, uint32: videoSSRC)
    response.add(0x07, uint32: audioSSRC)

    setupEndpointsResponse = response.build()
    return true
  }

  // MARK: - Selected RTP Stream Configuration (START/STOP/RECONFIGURE)

  private func handleSelectedRTPStreamConfig(_ value: Any) -> Bool {
    guard let b64 = value as? String, let data = Data(base64Encoded: b64) else { return false }
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]

    // Parse session control
    for (tag, val) in tlvs {
      if tag == 0x01 {
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        var command: UInt8 = 0
        for (stag, sval) in sub {
          if stag == 0x02, let c = sval.first { command = c }
        }

        switch command {
        case 1:  // START
          logger.info("Stream START requested")
          // Parse selected video params and RTP params
          var width: UInt16 = 1280
          var height: UInt16 = 720
          var fps: UInt8 = 30
          var maxBitrate: Int = 2000
          var payloadType: UInt8 = 99
          var audioPayloadType: UInt8 = 110
          for (ptag, pval) in tlvs {
            if ptag == 0x02 {  // Selected video parameters
              let vsub = TLV8.decode(pval) as [(UInt8, Data)]
              for (vtag, vval) in vsub {
                switch vtag {
                case 0x03:  // Video attributes (width, height, fps)
                  let attrSub = TLV8.decode(vval) as [(UInt8, Data)]
                  for (atag, aval) in attrSub {
                    switch atag {
                    case 0x01:
                      if aval.count >= 2 {
                        width =
                          UInt16(aval[aval.startIndex]) | UInt16(aval[aval.startIndex + 1]) << 8
                      }
                    case 0x02:
                      if aval.count >= 2 {
                        height =
                          UInt16(aval[aval.startIndex]) | UInt16(aval[aval.startIndex + 1]) << 8
                      }
                    case 0x03: if let f = aval.first { fps = f }
                    default: break
                    }
                  }
                case 0x04:  // Video RTP parameters (PT, SSRC, bitrate)
                  let rtpSub = TLV8.decode(vval) as [(UInt8, Data)]
                  for (rtag, rval) in rtpSub {
                    switch rtag {
                    case 0x01: if let pt = rval.first { payloadType = pt }  // Payload type
                    case 0x03:
                      if rval.count >= 2 {
                        maxBitrate = Int(
                          UInt16(rval[rval.startIndex]) | UInt16(rval[rval.startIndex + 1]) << 8)
                      }
                    default: break
                    }
                  }
                default: break
                }
              }
            } else if ptag == 0x03 {  // Selected audio parameters
              let asub = TLV8.decode(pval) as [(UInt8, Data)]
              for (atag, aval) in asub {
                if atag == 0x03 {  // Audio RTP parameters
                  let rtpSub = TLV8.decode(aval) as [(UInt8, Data)]
                  for (rtag, rval) in rtpSub {
                    if rtag == 0x01, let pt = rval.first { audioPayloadType = pt }
                  }
                }
              }
            }
          }
          logger.info(
            "Selected video: \(width)x\(height)@\(fps)fps, \(maxBitrate)kbps, PT=\(payloadType), audioPT=\(audioPayloadType)"
          )
          startStreaming(
            width: Int(width), height: Int(height), fps: Int(fps), bitrate: maxBitrate,
            payloadType: payloadType, audioPayloadType: audioPayloadType)

        case 0, 2:  // END(0) or RECONFIGURE(2) - for now treat reconfigure as restart
          logger.info("Stream \(command == 0 ? "STOP" : "RECONFIGURE") requested")
          stopStreaming()
        default:
          break
        }
      }
    }
    return true
  }

  // MARK: - Streaming Control

  /// Returns (videoRotationAngle, shouldSwapDimensions) based on current device orientation.
  /// The camera sensor's native orientation is landscape-left, so portrait requires a 90° rotation.
  private func currentRotation() -> (angle: Int, swapDimensions: Bool) {
    #if os(iOS)
      switch UIDevice.current.orientation {
      case .landscapeLeft: return (0, false)
      case .landscapeRight: return (180, false)
      case .portraitUpsideDown: return (270, true)
      default: return (90, true)  // portrait / unknown / faceUp / faceDown
      }
    #else
      return (0, false)  // macOS — no rotation needed
    #endif
  }

  /// Resolve the selected camera device, falling back to the default back wide-angle.
  private func resolveCamera() -> AVCaptureDevice? {
    if let id = selectedCameraID, let device = AVCaptureDevice(uniqueID: id) {
      return device
    }
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
  }

  private func startStreaming(
    width: Int, height: Int, fps: Int, bitrate: Int, payloadType: UInt8,
    audioPayloadType: UInt8 = 110
  ) {
    guard let session = streamSession else {
      logger.error("No stream session configured")
      return
    }

    guard let camera = resolveCamera() else {
      logger.error("No camera available for streaming")
      return
    }

    session.isMuted = isMuted
    session.speakerMuted = speakerMuted
    session.speakerVolume = speakerVolume
    session.onSnapshotFrame = { [weak self] jpeg in
      self?.cachedSnapshot = jpeg
    }

    let effectiveBitrate = max(bitrate, minimumBitrate)
    let rotation = currentRotation()
    logger.info(
      "Bitrate: negotiated=\(bitrate)kbps, minimum=\(self.minimumBitrate)kbps, effective=\(effectiveBitrate)kbps, rotation=\(rotation.angle)°"
    )
    session.startStreaming(
      width: width, height: height, fps: fps, bitrate: effectiveBitrate, payloadType: payloadType,
      audioPayloadType: audioPayloadType, camera: camera, rotationAngle: rotation.angle,
      swapDimensions: rotation.swapDimensions)
    onStateChange?(aid, Self.iidStreamingStatus, streamingStatusTLV().base64EncodedString())
  }

  private func stopStreaming() {
    streamSession?.stopStreaming()
    streamSession = nil
    onStateChange?(aid, Self.iidStreamingStatus, streamingStatusTLV().base64EncodedString())
  }

  // MARK: - Utility

  /// Returns the local IPv4 address on the same subnet as `peerAddress`.
  /// Falls back to any private address on en0 (WiFi) if no subnet match found.
  static func localIPAddress(matching peerAddress: String = "") -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    // Extract the peer's /24 prefix (e.g. "192.168.4.") for subnet matching
    let peerPrefix: String? = {
      let parts = peerAddress.split(separator: ".")
      guard parts.count == 4 else { return nil }
      return parts[0..<3].joined(separator: ".") + "."
    }()

    var subnetMatch: String?
    var wifiAddress: String?
    var anyPrivate: String?

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
      let flags = Int32(ptr.pointee.ifa_flags)
      guard (flags & (IFF_UP | IFF_RUNNING)) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
      let addr = ptr.pointee.ifa_addr.pointee
      guard addr.sa_family == UInt8(AF_INET) else { continue }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
          &hostname, socklen_t(hostname.count),
          nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let ip = String(cString: hostname)
      guard ip.hasPrefix("192.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") else { continue }

      let ifName = String(cString: ptr.pointee.ifa_name)

      // Best: same /24 subnet as the controller
      if let prefix = peerPrefix, ip.hasPrefix(prefix), subnetMatch == nil {
        subnetMatch = ip
      }
      // Good: WiFi interface
      if ifName == "en0", wifiAddress == nil {
        wifiAddress = ip
      }
      // Fallback: any private address
      if anyPrivate == nil {
        anyPrivate = ip
      }
    }
    return subnetMatch ?? wifiAddress ?? anyPrivate
  }

  // MARK: - Snapshot

  /// Capture a single JPEG frame from the selected camera synchronously.
  /// Uses AVCaptureVideoDataOutput instead of AVCapturePhotoOutput to avoid
  /// the system shutter sound. Falls back to a cached frame from the last
  /// active stream when a fresh capture isn't possible.
  func captureSnapshot(width: Int, height: Int) -> Data? {
    // If streaming is active, return the cached frame (can't run two sessions
    // on the same camera simultaneously).
    if streamSession != nil {
      logger.info("Stream active — returning cached snapshot")
      return cachedSnapshot
    }

    guard let camera = resolveCamera() else {
      logger.error("No camera available for snapshot")
      return cachedSnapshot
    }

    // Pause other capture sessions (e.g. ambient light monitor) — iOS only
    // allows one AVCaptureSession at a time per camera, and even sessions on
    // different cameras can interfere with each other.
    onSnapshotWillCapture?()
    defer { onSnapshotDidCapture?() }

    let session = AVCaptureSession()
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
    if let connection = videoOutput.connection(with: .video),
      connection.isVideoRotationAngleSupported(CGFloat(rotation.angle))
    {
      connection.videoRotationAngle = CGFloat(rotation.angle)
    }

    // Skip early frames so auto-exposure has time to converge; the very
    // first frames from a cold-started session are often black/dark.
    let grabber = FrameGrabber(framesToSkip: 10)
    let queue = DispatchQueue(label: "me.fausak.taylor.Pylo.snapshot", qos: .userInteractive)
    videoOutput.setSampleBufferDelegate(grabber, queue: queue)

    session.startRunning()
    defer { session.stopRunning() }

    // Wait up to 3 seconds for a usable frame
    _ = grabber.semaphore.wait(timeout: .now() + 3)

    guard let pixelBuffer = grabber.pixelBuffer else {
      logger.warning("Frame grab timed out — returning cached snapshot")
      return cachedSnapshot
    }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let jpeg = context.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:])
    else { return cachedSnapshot }

    cachedSnapshot = jpeg
    return jpeg
  }

  // MARK: - JSON Serialization

  func toJSON() -> [String: Any] {
    [
      "aid": aid,
      "services": [
        accessoryInformationServiceJSON(),
        // Camera RTP Stream Management Service
        [
          "iid": Self.iidCameraService,
          "type": Self.uuidCameraRTPStreamManagement,
          "characteristics": [
            [
              "iid": Self.iidSupportedVideoConfig,
              "type": Self.uuidSupportedVideoStreamConfig,
              "format": "tlv8",
              "perms": ["pr"],
              "value": Self.supportedVideoConfig().base64(),
            ],
            [
              "iid": Self.iidSupportedAudioConfig,
              "type": Self.uuidSupportedAudioStreamConfig,
              "format": "tlv8",
              "perms": ["pr"],
              "value": Self.supportedAudioConfig().base64(),
            ],
            [
              "iid": Self.iidSupportedRTPConfig,
              "type": Self.uuidSupportedRTPConfig,
              "format": "tlv8",
              "perms": ["pr"],
              "value": Self.supportedRTPConfig().base64(),
            ],
            [
              "iid": Self.iidSetupEndpoints,
              "type": Self.uuidSetupEndpoints, "format": "tlv8",
              "perms": ["pr", "pw"], "value": "",
            ],
            [
              "iid": Self.iidSelectedRTPStreamConfig,
              "type": Self.uuidSelectedRTPStreamConfig,
              "format": "tlv8",
              "perms": ["pr", "pw"], "value": "",
            ],
            [
              "iid": Self.iidStreamingStatus,
              "type": Self.uuidStreamingStatus, "format": "tlv8",
              "perms": ["pr", "ev"],
              "value": streamingStatusTLV().base64EncodedString(),
            ],
          ],
        ],
        // Microphone Service
        [
          "iid": Self.iidMicrophoneService,
          "type": Self.uuidMicrophone,
          "characteristics": [
            [
              "iid": Self.iidMicrophoneMute,
              "type": Self.uuidMute, "format": "bool",
              "perms": ["pr", "pw", "ev"], "value": isMuted,
            ]
          ],
        ],
        // Speaker Service
        [
          "iid": Self.iidSpeakerService,
          "type": Self.uuidSpeaker,
          "characteristics": [
            [
              "iid": Self.iidSpeakerMute,
              "type": Self.uuidMute, "format": "bool",
              "perms": ["pr", "pw", "ev"], "value": speakerMuted,
            ],
            [
              "iid": Self.iidSpeakerVolume,
              "type": Self.uuidVolume, "format": "uint8",
              "perms": ["pr", "pw", "ev"], "value": speakerVolume,
              "minValue": 0, "maxValue": 100, "minStep": 1,
            ],
          ],
        ],
      ],
    ]
  }
}

// MARK: - Frame Grabber (for silent snapshots)

private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  let semaphore = DispatchSemaphore(value: 0)
  var pixelBuffer: CVPixelBuffer?
  private let framesToSkip: Int
  private var framesReceived = 0

  init(framesToSkip: Int = 0) {
    self.framesToSkip = framesToSkip
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard pixelBuffer == nil else { return }
    framesReceived += 1
    // Skip early frames so auto-exposure can settle.
    guard framesReceived > framesToSkip else { return }
    pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    semaphore.signal()
  }
}

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
  var isMuted: Bool = false

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
  var speakerMuted: Bool = false
  var speakerVolume: Int = 100

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

    if let session = captureSession {
      DispatchQueue.global(qos: .background).async { session.stopRunning() }
    }
    captureSession = nil

    if let cs = compressionSession {
      VTCompressionSessionInvalidate(cs)
    }
    compressionSession = nil

    if videoSocketFD >= 0 {
      close(videoSocketFD)
      videoSocketFD = -1
    }
    controllerVideoAddr = nil
    srtpContext = nil

    // Audio mic cleanup
    audioRTCPTimer?.cancel()
    audioRTCPTimer = nil
    audioOutput = nil

    if let enc = audioConverter {
      AudioConverterDispose(enc)
    }
    audioConverter = nil
    pcmAccumulator = Data()

    // Audio socket cleanup
    audioReadSource?.cancel()
    audioReadSource = nil
    if audioSocketFD >= 0 {
      close(audioSocketFD)
      audioSocketFD = -1
    }
    controllerAudioAddr = nil
    audioSRTPContext = nil
    audioSampleCount = 0
    incomingAudioPacketCount = 0

    // Audio speaker cleanup
    audioPlayerNode?.stop()
    audioPlayerNode = nil
    audioPlayerStarted = false
    audioEngine?.stop()
    audioEngine = nil

    if let dec = audioDecoder {
      AudioConverterDispose(dec)
    }
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
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
      if let jpeg = snapshotCIContext.jpegRepresentation(
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
    if status != noErr {
      logger.error("AudioConverter (encoder) create failed: \(status)")
      return
    }

    // Set bitrate to 24kbps (good quality for voice)
    var bitrate: UInt32 = 24000
    AudioConverterSetProperty(
      converter!, kAudioConverterEncodeBitRate,
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
          // Mix down to mono
          for i in stride(from: 0, to: floatPtr.count, by: sourceChannels) {
            floatSamples.append(floatPtr[i])
          }
        }
      }
    } else if is16Bit {
      // Int16 → Float32
      data.withUnsafeBytes { ptr in
        let int16Ptr = ptr.bindMemory(to: Int16.self)
        for i in stride(from: 0, to: int16Ptr.count, by: sourceChannels) {
          floatSamples.append(Float(int16Ptr[i]) / 32768.0)
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

// MARK: - AU Header (RFC 3640)

/// RFC 3640 AU header helpers for AAC-ELD framing used by HomeKit.
enum AUHeader {

  /// Prepend a 4-byte RFC 3640 AU header section to raw AAC data.
  /// Layout: 2-byte AU-headers-length (0x0010 = one 16-bit AU header)
  ///       + 2-byte AU header (13-bit AU-size << 3 | AU-Index=0).
  static func add(to aacData: Data) -> Data {
    let auSize = UInt16(aacData.count)
    var header = Data(count: 4)
    header[0] = 0x00  // AU-headers-length MSB
    header[1] = 0x10  // AU-headers-length LSB = 16 bits
    header[2] = UInt8((auSize << 3) >> 8)  // AU-size upper bits
    header[3] = UInt8((auSize << 3) & 0xFF)  // AU-size lower bits + AU-Index=0
    var result = header
    result.append(aacData)
    return result
  }

  /// Strip the 4-byte RFC 3640 AU header if present, otherwise return data unchanged.
  static func strip(from payload: Data) -> Data {
    guard payload.count >= 4,
      payload[payload.startIndex] == 0x00,
      payload[payload.startIndex + 1] == 0x10
    else {
      return payload
    }
    return Data(payload[payload.startIndex + 4..<payload.endIndex])
  }
}

// MARK: - SRTP Context

/// Minimal SRTP implementation using AES-128-ICM + HMAC-SHA1-80.
/// Handles key derivation and per-packet encryption/authentication per RFC 3711.
final class SRTPContext {

  private let masterKey: Data  // 16 bytes
  private let masterSalt: Data  // 14 bytes

  // Derived SRTP session keys
  private let sessionKey: Data  // 16 bytes — AES encryption key
  private let sessionSalt: Data  // 14 bytes — IV/counter salt
  private let sessionAuthKey: Data  // 20 bytes — HMAC-SHA1 key

  // Derived SRTCP session keys (labels 0x03, 0x04, 0x05)
  private let srtcpKey: Data
  private let srtcpSalt: Data
  private let srtcpAuthKey: Data

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "SRTP")
  private var rolloverCounter: UInt32 = 0
  private var lastSequenceNumber: UInt16 = 0
  private var packetCount: Int = 0
  private var srtcpIndex: UInt32 = 0

  // Incoming (receive) direction ROC tracking — separate from outgoing
  private var incomingROC: UInt32 = 0
  private var incomingLastSeq: UInt16 = 0
  private var incomingInitialized: Bool = false

  init(masterKey: Data, masterSalt: Data) {
    self.masterKey = masterKey
    self.masterSalt = masterSalt

    // Derive SRTP session keys via AES-CM PRF (RFC 3711 §4.3.1)
    self.sessionKey = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x00, length: 16)
    self.sessionSalt = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x02, length: 14)
    self.sessionAuthKey = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x01, length: 20)

    // Derive SRTCP session keys (RFC 3711 §4.3.1, labels 0x03-0x05)
    self.srtcpKey = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x03, length: 16)
    self.srtcpSalt = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x05, length: 14)
    self.srtcpAuthKey = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x04, length: 20)

    logger.debug(
      "SRTP keys derived (master=\(masterKey.count)B, session=\(self.sessionKey.count)B)")

    // Self-test key derivation against RFC 3711 Appendix B.3
    Self.runSelfTest()
  }

  /// Verify key derivation against RFC 3711 Appendix B.3 test vectors.
  private static func runSelfTest() {
    let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "SRTP")
    let testKey = Data([
      0xE1, 0xF9, 0x7A, 0x0D, 0x3E, 0x01, 0x8B, 0xE0,
      0xD6, 0x4F, 0xA3, 0x2C, 0x06, 0xDE, 0x41, 0x39,
    ])
    let testSalt = Data([
      0x0E, 0xC6, 0x75, 0xAD, 0x49, 0x8A, 0xFE, 0xEB,
      0xB6, 0x96, 0x0B, 0x3A, 0xAB, 0xE6,
    ])
    let expectedCipherKey = Data([
      0xC6, 0x1E, 0x7A, 0x93, 0x74, 0x4F, 0x39, 0xEE,
      0x10, 0x73, 0x4A, 0xFE, 0x3F, 0xF7, 0xA0, 0x87,
    ])
    let expectedSalt = Data([
      0x30, 0xCB, 0xBC, 0x08, 0x86, 0x3D, 0x8C, 0x85,
      0xD4, 0x9D, 0xB3, 0x4A, 0x9A, 0xE1,
    ])
    let expectedAuthKey = Data([
      0xCE, 0xBE, 0x32, 0x1F, 0x6F, 0xF7, 0x71, 0x6B,
      0x6F, 0xD4, 0xAB, 0x49, 0xAF, 0x25, 0x6A, 0x15,
      0x6D, 0x38, 0xBA, 0xA4,
    ])

    let ck = deriveKey(masterKey: testKey, masterSalt: testSalt, label: 0x00, length: 16)
    let cs = deriveKey(masterKey: testKey, masterSalt: testSalt, label: 0x02, length: 14)
    let ak = deriveKey(masterKey: testKey, masterSalt: testSalt, label: 0x01, length: 20)

    let pass = (ck == expectedCipherKey && cs == expectedSalt && ak == expectedAuthKey)
    logger.info("SRTP self-test: \(pass ? "PASS" : "FAIL")")
    if !pass {
      logger.error(
        "SRTP self-test FAILED! cipher=\(ck == expectedCipherKey) salt=\(cs == expectedSalt) auth=\(ak == expectedAuthKey)"
      )
      logger.error("  Got cipher: \(ck.map { String(format: "%02x", $0) }.joined())")
      logger.error("  Expected:   \(expectedCipherKey.map { String(format: "%02x", $0) }.joined())")
    }
  }

  /// Encrypt and authenticate an RTP packet in place, returning the SRTP packet.
  func protect(_ rtpPacket: Data) -> Data {
    guard rtpPacket.count >= 12 else { return rtpPacket }

    let header = Data(rtpPacket[rtpPacket.startIndex..<rtpPacket.startIndex + 12])
    let payload = Data(rtpPacket[rtpPacket.startIndex + 12..<rtpPacket.endIndex])

    // Extract SSRC and sequence number from header
    let ssrc =
      UInt32(header[header.startIndex + 8]) << 24 | UInt32(header[header.startIndex + 9]) << 16
      | UInt32(header[header.startIndex + 10]) << 8 | UInt32(header[header.startIndex + 11])
    let seq = UInt16(header[header.startIndex + 2]) << 8 | UInt16(header[header.startIndex + 3])

    // Track rollover counter
    if seq < lastSequenceNumber && (lastSequenceNumber - seq) > 0x8000 {
      rolloverCounter += 1
    }
    lastSequenceNumber = seq

    // Packet index = ROC * 65536 + SEQ
    let packetIndex = UInt64(rolloverCounter) << 16 | UInt64(seq)

    // Build the IV for AES-ICM (RFC 3711 §4.1.1)
    // IV = (k_s * 2^16) XOR (SSRC * 2^64) XOR (i * 2^16)
    // k_s (14 bytes) at bytes 0-13, SSRC (4 bytes) at bytes 4-7,
    // packet index (6 bytes) at bytes 8-13, block counter at bytes 14-15
    var iv = Data(count: 16)
    iv[4] = UInt8((ssrc >> 24) & 0xFF)
    iv[5] = UInt8((ssrc >> 16) & 0xFF)
    iv[6] = UInt8((ssrc >> 8) & 0xFF)
    iv[7] = UInt8(ssrc & 0xFF)
    iv[8] = UInt8((packetIndex >> 40) & 0xFF)
    iv[9] = UInt8((packetIndex >> 32) & 0xFF)
    iv[10] = UInt8((packetIndex >> 24) & 0xFF)
    iv[11] = UInt8((packetIndex >> 16) & 0xFF)
    iv[12] = UInt8((packetIndex >> 8) & 0xFF)
    iv[13] = UInt8(packetIndex & 0xFF)

    // XOR with session salt (14 bytes at bytes 0-13)
    for i in 0..<min(14, sessionSalt.count) {
      iv[i] ^= sessionSalt[sessionSalt.startIndex + i]
    }

    // Encrypt payload with AES-128-CTR
    let encryptedPayload = aesCTREncrypt(key: sessionKey, iv: iv, data: Data(payload))

    packetCount += 1

    // Assemble: original header + encrypted payload
    var srtpPacket = Data(header)
    srtpPacket.append(encryptedPayload)

    // Compute HMAC-SHA1 authentication tag over (header + encrypted payload + ROC)
    var authInput = srtpPacket
    var roc = rolloverCounter.bigEndian
    authInput.append(Data(bytes: &roc, count: 4))

    let tag = hmacSHA1(key: sessionAuthKey, data: authInput)
    srtpPacket.append(tag.prefix(10))  // Truncate to 80 bits

    return srtpPacket
  }

  /// Decrypt and verify an incoming SRTP packet, returning the plain RTP packet.
  /// Returns nil if authentication fails.
  func unprotect(_ srtpPacket: Data) -> Data? {
    // SRTP = RTP header (12+) || encrypted payload || auth tag (10 bytes)
    guard srtpPacket.count >= 22 else { return nil }  // 12 header + 0 payload + 10 tag

    let tagStart = srtpPacket.count - 10
    let receivedTag = Data(srtpPacket[srtpPacket.startIndex + tagStart..<srtpPacket.endIndex])
    let authenticated = Data(srtpPacket[srtpPacket.startIndex..<srtpPacket.startIndex + tagStart])

    // Extract sequence number from header
    let seq =
      UInt16(authenticated[authenticated.startIndex + 2]) << 8
      | UInt16(authenticated[authenticated.startIndex + 3])

    // Track incoming ROC
    if !incomingInitialized {
      incomingLastSeq = seq
      incomingInitialized = true
    } else if seq < incomingLastSeq && (incomingLastSeq - seq) > 0x8000 {
      incomingROC += 1
    }
    incomingLastSeq = seq

    // Verify HMAC-SHA1-80
    var authInput = authenticated
    var roc = incomingROC.bigEndian
    authInput.append(Data(bytes: &roc, count: 4))
    let expectedTag = hmacSHA1(key: sessionAuthKey, data: authInput)
    guard receivedTag == expectedTag.prefix(10) else {
      logger.debug("SRTP unprotect: auth tag mismatch")
      return nil
    }

    // Extract SSRC and build IV (same as protect)
    let header = Data(authenticated[authenticated.startIndex..<authenticated.startIndex + 12])
    let encryptedPayload = Data(
      authenticated[authenticated.startIndex + 12..<authenticated.endIndex])

    let ssrc =
      UInt32(header[header.startIndex + 8]) << 24 | UInt32(header[header.startIndex + 9]) << 16
      | UInt32(header[header.startIndex + 10]) << 8 | UInt32(header[header.startIndex + 11])

    let packetIndex = UInt64(incomingROC) << 16 | UInt64(seq)

    var iv = Data(count: 16)
    iv[4] = UInt8((ssrc >> 24) & 0xFF)
    iv[5] = UInt8((ssrc >> 16) & 0xFF)
    iv[6] = UInt8((ssrc >> 8) & 0xFF)
    iv[7] = UInt8(ssrc & 0xFF)
    iv[8] = UInt8((packetIndex >> 40) & 0xFF)
    iv[9] = UInt8((packetIndex >> 32) & 0xFF)
    iv[10] = UInt8((packetIndex >> 24) & 0xFF)
    iv[11] = UInt8((packetIndex >> 16) & 0xFF)
    iv[12] = UInt8((packetIndex >> 8) & 0xFF)
    iv[13] = UInt8(packetIndex & 0xFF)

    for i in 0..<min(14, sessionSalt.count) {
      iv[i] ^= sessionSalt[sessionSalt.startIndex + i]
    }

    // AES-CTR decrypt (symmetric — same as encrypt)
    let decryptedPayload = aesCTREncrypt(key: sessionKey, iv: iv, data: encryptedPayload)

    var rtpPacket = Data(header)
    rtpPacket.append(decryptedPayload)
    return rtpPacket
  }

  /// Encrypt and authenticate an RTCP packet, returning the SRTCP packet.
  /// Format: RTCP_header(8B) || encrypted_payload || E_flag+SRTCP_index(4B) || auth_tag(10B)
  func protectRTCP(_ rtcpPacket: Data) -> Data {
    guard rtcpPacket.count >= 8 else { return rtcpPacket }

    let header = Data(rtcpPacket[rtcpPacket.startIndex..<rtcpPacket.startIndex + 8])
    let payload = Data(rtcpPacket[rtcpPacket.startIndex + 8..<rtcpPacket.endIndex])

    // Extract SSRC from header (bytes 4-7)
    let ssrc =
      UInt32(header[header.startIndex + 4]) << 24 | UInt32(header[header.startIndex + 5]) << 16
      | UInt32(header[header.startIndex + 6]) << 8 | UInt32(header[header.startIndex + 7])

    let index = srtcpIndex
    srtcpIndex += 1

    // Build IV: (srtcp_salt * 2^16) XOR (SSRC * 2^64) XOR (index * 2^16)
    var iv = Data(count: 16)
    iv[4] = UInt8((ssrc >> 24) & 0xFF)
    iv[5] = UInt8((ssrc >> 16) & 0xFF)
    iv[6] = UInt8((ssrc >> 8) & 0xFF)
    iv[7] = UInt8(ssrc & 0xFF)
    // SRTCP index is 32-bit (not 48-bit like SRTP packet index), placed at bytes 10-13
    iv[10] = UInt8((index >> 24) & 0xFF)
    iv[11] = UInt8((index >> 16) & 0xFF)
    iv[12] = UInt8((index >> 8) & 0xFF)
    iv[13] = UInt8(index & 0xFF)

    for i in 0..<min(14, srtcpSalt.count) {
      iv[i] ^= srtcpSalt[srtcpSalt.startIndex + i]
    }

    let encryptedPayload = aesCTREncrypt(key: srtcpKey, iv: iv, data: payload)

    // Assemble: header + encrypted payload + E||index + auth tag
    var srtcpPacket = Data(header)
    srtcpPacket.append(encryptedPayload)

    // E flag (bit 31) = 1 (encrypted) + 31-bit SRTCP index
    let eIndex = (UInt32(1) << 31) | (index & 0x7FFF_FFFF)
    var eIndexBE = eIndex.bigEndian
    srtcpPacket.append(Data(bytes: &eIndexBE, count: 4))

    // Auth tag covers: header + encrypted payload + E||index
    let tag = hmacSHA1(key: srtcpAuthKey, data: srtcpPacket)
    srtcpPacket.append(tag.prefix(10))

    return srtcpPacket
  }

  // MARK: - Key Derivation (AES-CM PRF)

  /// RFC 3711 §4.3.1 — derive a session key using AES-CM as a PRF.
  static func deriveKey(masterKey: Data, masterSalt: Data, label: UInt8, length: Int)
    -> Data
  {
    // x = label || 0x000000000000 (7 bytes) — then r = salt XOR (x left-padded to 14 bytes)
    var r = Data(count: 14)
    // Copy salt
    for i in 0..<min(14, masterSalt.count) {
      r[i] = masterSalt[masterSalt.startIndex + i]
    }
    // XOR label at byte index 7 (within the 14-byte block)
    r[7] ^= label

    // Build IV: r || 0x0000 (pad to 16 bytes)
    var iv = Data(count: 16)
    for i in 0..<14 { iv[i] = r[i] }
    // iv[14] = 0, iv[15] = 0 (block counter = 0)

    // Generate keystream by encrypting the IV with AES-ECB (counter mode with counter = 0,1,...)
    var result = Data()
    var counter: UInt16 = 0
    while result.count < length {
      iv[14] = UInt8(counter >> 8)
      iv[15] = UInt8(counter & 0xFF)

      // Buffer must be >= inputLength + blockSize for CCCrypt
      var block = Data(count: 32)
      var outLength = 0
      let status = block.withUnsafeMutableBytes { outPtr in
        iv.withUnsafeBytes { ivPtr in
          masterKey.withUnsafeBytes { keyPtr in
            CCCrypt(
              CCOperation(kCCEncrypt),
              CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionECBMode),
              keyPtr.baseAddress, masterKey.count,
              nil,
              ivPtr.baseAddress, 16,
              outPtr.baseAddress, 32,
              &outLength
            )
          }
        }
      }
      if status != kCCSuccess || outLength == 0 {
        // Fallback: should never happen
        break
      }
      result.append(block.prefix(min(outLength, 16)))
      counter += 1
    }
    return Data(result.prefix(length))
  }

  // MARK: - AES-128-CTR Encryption

  private func aesCTREncrypt(key: Data, iv: Data, data: Data) -> Data {
    guard !data.isEmpty else { return data }

    var cryptorRef: CCCryptorRef?
    let createStatus = key.withUnsafeBytes { keyPtr in
      iv.withUnsafeBytes { ivPtr in
        CCCryptorCreateWithMode(
          CCOperation(kCCEncrypt),
          CCMode(kCCModeCTR),
          CCAlgorithm(kCCAlgorithmAES),
          CCPadding(ccNoPadding),
          ivPtr.baseAddress,
          keyPtr.baseAddress, key.count,
          nil, 0, 0,
          CCModeOptions(kCCModeOptionCTR_BE),
          &cryptorRef
        )
      }
    }

    guard createStatus == kCCSuccess, let cryptor = cryptorRef else {
      return data  // Fallback: return plaintext (shouldn't happen)
    }

    let resultCount = data.count
    var result = Data(count: resultCount)
    var outLength = 0
    let updateStatus = result.withUnsafeMutableBytes { outPtr in
      data.withUnsafeBytes { inPtr in
        CCCryptorUpdate(
          cryptor,
          inPtr.baseAddress, data.count,
          outPtr.baseAddress, resultCount,
          &outLength
        )
      }
    }

    CCCryptorRelease(cryptor)

    if updateStatus != kCCSuccess {
      return data
    }

    return result
  }

  // MARK: - HMAC-SHA1

  private func hmacSHA1(key: Data, data: Data) -> Data {
    var result = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
    result.withUnsafeMutableBytes { resultPtr in
      data.withUnsafeBytes { dataPtr in
        key.withUnsafeBytes { keyPtr in
          CCHmac(
            CCHmacAlgorithm(kCCHmacAlgSHA1),
            keyPtr.baseAddress, key.count,
            dataPtr.baseAddress, data.count,
            resultPtr.baseAddress
          )
        }
      }
    }
    return result
  }
}
