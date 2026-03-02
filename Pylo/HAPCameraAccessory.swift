@preconcurrency import AVFoundation
import CoreImage
import CryptoKit
import FragmentedMP4
import Foundation
import HAP
import TLV8
@preconcurrency import UIKit
import os

// MARK: - Camera Option

/// A camera that can be used for video streaming.
struct CameraOption: Identifiable, Hashable, Sendable {
  let id: String  // AVCaptureDevice.uniqueID
  let name: String
  let fNumber: Float

  static func availableCameras() -> [CameraOption] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
      mediaType: .video,
      position: .unspecified
    )
    return discovery.devices.map { device in
      CameraOption(
        id: device.uniqueID,
        name: device.localizedName,
        fNumber: device.lensAperture
      )
    }
  }
}

// MARK: - Camera Accessory

/// HAP camera sub-accessory exposing CameraRTPStreamManagement.
/// Handles the full pipeline: TLV8 negotiation → video capture → H.264 → RTP → SRTP → UDP.
nonisolated final class HAPCameraAccessory: HAPAccessoryProtocol, HAPSnapshotProvider,
  @unchecked Sendable
{

  let aid: Int
  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String

  private let _onStateChange = OSAllocatedUnfairLock<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  private let _batteryState = OSAllocatedUnfairLock<BatteryState?>(initialState: nil)
  var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  /// Callback closures set once during setup and called from the server queue.
  /// Protected by a lock since they are written from createServerSetup (off-main)
  /// and read from the server queue.
  private struct Callbacks {
    var onSnapshotWillCapture: (() -> Void)?
    var onSnapshotDidCapture: (() -> Void)?
    var onMonitoringCaptureNeeded: ((_ needed: Bool) -> Void)?
    var onVideoMotionChange: ((Bool) -> Void)?
    var onRecordingConfigChange: ((_ active: Bool) -> Void)?
    var onRecordingAudioActiveChange: ((_ active: Bool) -> Void)?
    var onSelectedRecordingConfigChange: ((_ config: Data) -> Void)?
    var onSetupDataStream: ((_ requestData: Data, _ sharedSecret: SharedSecret?, _ respond: @escaping (Data) -> Void) -> Void)?
  }
  private let _callbacks = OSAllocatedUnfairLock(initialState: Callbacks())

  var onSnapshotWillCapture: (() -> Void)? {
    get { _callbacks.withLock { $0.onSnapshotWillCapture } }
    set { _callbacks.withLock { $0.onSnapshotWillCapture = newValue } }
  }
  var onSnapshotDidCapture: (() -> Void)? {
    get { _callbacks.withLock { $0.onSnapshotDidCapture } }
    set { _callbacks.withLock { $0.onSnapshotDidCapture = newValue } }
  }
  var onMonitoringCaptureNeeded: ((_ needed: Bool) -> Void)? {
    get { _callbacks.withLock { $0.onMonitoringCaptureNeeded } }
    set { _callbacks.withLock { $0.onMonitoringCaptureNeeded = newValue } }
  }
  var onVideoMotionChange: ((Bool) -> Void)? {
    get { _callbacks.withLock { $0.onVideoMotionChange } }
    set { _callbacks.withLock { $0.onVideoMotionChange = newValue } }
  }

  /// Whether video motion detection is active on the streaming session.
  /// Protected by streamLock so the Bool storage itself is synchronized.
  private var _videoMotionEnabled: Bool = false
  var videoMotionEnabled: Bool {
    get { streamLock.withLock { _videoMotionEnabled } }
    set {
      streamLock.withLock {
        _videoMotionEnabled = newValue
        if newValue {
          let detector = VideoMotionDetector()
          detector.onMotionChange = { [weak self] detected in
            self?.onVideoMotionChange?(detected)
          }
          _videoMotionDetector = detector
          _streamSession?.videoMotionDetector = detector
        } else {
          _videoMotionDetector?.reset()
          _videoMotionDetector = nil
          _streamSession?.videoMotionDetector = nil
        }
      }
    }
  }

  /// Lock protecting _videoMotionDetector and _streamSession, which are
  /// accessed from both createServerSetup (off-main) and the server queue.
  private let streamLock = NSLock()
  private var _videoMotionDetector: VideoMotionDetector?
  var videoMotionDetector: VideoMotionDetector? {
    get { streamLock.withLock { _videoMotionDetector } }
    set { streamLock.withLock { _videoMotionDetector = newValue } }
  }

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Camera")

  /// Reusable CIContext for snapshot JPEG encoding (CIContext is expensive to allocate).
  private let snapshotCIContext = CIContext()

  /// Which camera to use for streaming and snapshots (nil = default back wide-angle).
  var selectedCameraID: String?

  /// Minimum bitrate (kbps) to use regardless of what the controller negotiates.
  var minimumBitrate: Int = 0

  /// Active streaming session (nil when idle).
  private var _streamSession: CameraStreamSession?
  var streamSession: CameraStreamSession? {
    get { streamLock.withLock { _streamSession } }
    set { streamLock.withLock { _streamSession = newValue } }
  }

  /// Most recent JPEG snapshot captured during streaming (used as fallback for snapshot requests).
  /// Protected by a lock because it is written from captureQueue (via onSnapshotFrame) and from
  /// a global queue (captureSnapshot), and read from the server queue.
  private let snapshotLock = NSLock()
  private var _cachedSnapshot: Data?
  private var cachedSnapshot: Data? {
    get { snapshotLock.withLock { _cachedSnapshot } }
    set { snapshotLock.withLock { _cachedSnapshot = newValue } }
  }

  /// Audio settings accessed from the server queue (read/write characteristics)
  /// and from CameraStreamSession (on capture/rtp queues).
  private struct AudioSettings {
    var isMuted: Bool = false
    var speakerMuted: Bool = false
    var speakerVolume: Int = 100
  }
  private let audioSettings = OSAllocatedUnfairLock(initialState: AudioSettings())

  // MARK: - HKSV State

  /// Camera Operating Mode state
  private(set) var homeKitCameraActive: Bool = true
  private(set) var eventSnapshotsActive: Bool = true
  private(set) var periodicSnapshotsActive: Bool = true

  /// Camera Event Recording Management state
  private(set) var recordingActive: UInt8 = 0  // 0=disabled, 1=enabled
  private(set) var recordingAudioActive: UInt8 = 0
  private(set) var selectedRecordingConfig = Data()

  /// Restores `recordingActive` from persisted state without triggering callbacks.
  /// Must be called before wiring `onRecordingConfigChange` / `onMonitoringCaptureNeeded`.
  func restoreRecordingActive(_ value: UInt8) {
    recordingActive = value
  }

  /// Restores `recordingAudioActive` from persisted state without triggering callbacks.
  func restoreRecordingAudioActive(_ value: UInt8) {
    recordingAudioActive = value
  }

  /// Restores `selectedRecordingConfig` from persisted state.
  func restoreSelectedRecordingConfig(_ data: Data) {
    selectedRecordingConfig = data
  }

  /// Shared fMP4 writer for HKSV pre-buffering.  Set by the host so it can be
  /// forwarded to `CameraStreamSession` during live streams.
  var fragmentWriter: FragmentedMP4Writer?

  /// Motion sensor state (linked to this camera accessory)
  private let _isMotionDetected = OSAllocatedUnfairLock(initialState: false)
  var isMotionDetected: Bool {
    _isMotionDetected.withLock { $0 }
  }

  /// Whether HKSV services are enabled on this accessory.
  var hksvEnabled: Bool = false

  var onRecordingConfigChange: ((_ active: Bool) -> Void)? {
    get { _callbacks.withLock { $0.onRecordingConfigChange } }
    set { _callbacks.withLock { $0.onRecordingConfigChange = newValue } }
  }
  var onRecordingAudioActiveChange: ((_ active: Bool) -> Void)? {
    get { _callbacks.withLock { $0.onRecordingAudioActiveChange } }
    set { _callbacks.withLock { $0.onRecordingAudioActiveChange = newValue } }
  }
  var onSelectedRecordingConfigChange: ((_ config: Data) -> Void)? {
    get { _callbacks.withLock { $0.onSelectedRecordingConfigChange } }
    set { _callbacks.withLock { $0.onSelectedRecordingConfigChange = newValue } }
  }

  /// Active characteristic on CameraRTPStreamManagement — indicates whether
  /// the streaming service is enabled. Written by the HomeKit hub.
  private(set) var rtpStreamActive: UInt8 = 1

  // Pending setup endpoint response (written by controller, read back after).
  // Protected by lock since writes happen from the server queue and snapshot
  // capture can trigger handleSetupEndpoints from another queue.
  private let _setupEndpointsResponse = OSAllocatedUnfairLock(initialState: Data())
  private var setupEndpointsResponse: Data {
    get { _setupEndpointsResponse.withLock { $0 } }
    set { _setupEndpointsResponse.withLock { $0 = newValue } }
  }

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

  // Camera Operating Mode Service (iid 20-22)
  static let iidOperatingModeService = 20
  static let iidHomeKitCameraActive = 21
  static let iidEventSnapshotsActive = 22
  static let iidPeriodicSnapshotsActive = 23

  // Camera Event Recording Management Service (iid 30-35)
  static let iidRecordingManagementService = 30
  static let iidRecordingActive = 31
  static let iidSupportedCameraRecordingConfig = 32
  static let iidSupportedVideoRecordingConfig = 33
  static let iidSupportedAudioRecordingConfig = 34
  static let iidSelectedCameraRecordingConfig = 35
  static let iidRecordingAudioActive = 36

  // Active characteristic on CameraRTPStreamManagement (iid 37)
  static let iidRTPStreamActive = 37

  // Motion Sensor linked to camera (iid 50-51)
  static let iidMotionSensorService = 50
  static let iidMotionDetected = 51

  // DataStream Transport Management Service (iid 60-62)
  static let iidDataStreamService = 60
  static let iidSupportedDataStreamConfig = 61
  static let iidSetupDataStreamTransport = 62
  static let iidDataStreamVersion = 63

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
  static let uuidActive = "B0"

  // Camera Operating Mode UUIDs
  static let uuidCameraOperatingMode = "21A"
  static let uuidHomeKitCameraActive = "21B"
  static let uuidEventSnapshotsActive = "223"
  static let uuidPeriodicSnapshotsActive = "225"

  // Camera Event Recording Management UUIDs
  static let uuidCameraEventRecordingManagement = "204"
  static let uuidSupportedCameraRecordingConfig = "205"
  static let uuidSupportedVideoRecordingConfig = "206"
  static let uuidSupportedAudioRecordingConfig = "207"
  static let uuidSelectedCameraRecordingConfig = "209"
  static let uuidRecordingAudioActive = "226"

  // Motion Sensor UUIDs
  static let uuidMotionSensor = "85"
  static let uuidMotionDetected = "22"

  // DataStream Transport Management UUIDs
  static let uuidDataStreamTransportManagement = "129"
  static let uuidSupportedDataStreamTransportConfig = "130"
  static let uuidSetupDataStreamTransport = "131"
  static let uuidVersion = "37"

  // MARK: - Read Characteristic

  func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case Self.iidSupportedVideoConfig:
      return .string(Self.supportedVideoConfig().base64())
    case Self.iidSupportedAudioConfig:
      return .string(Self.supportedAudioConfig().base64())
    case Self.iidSupportedRTPConfig:
      return .string(Self.supportedRTPConfig().base64())
    case Self.iidSetupEndpoints:
      return .string(setupEndpointsResponse.base64EncodedString())
    case Self.iidSelectedRTPStreamConfig:
      return .string("")  // write-only effectively
    case Self.iidStreamingStatus:
      return .string(streamingStatusTLV().base64EncodedString())
    case Self.iidMicrophoneMute: return .bool(audioSettings.withLock { $0.isMuted })
    case Self.iidSpeakerMute: return .bool(audioSettings.withLock { $0.speakerMuted })
    case Self.iidSpeakerVolume: return .int(audioSettings.withLock { $0.speakerVolume })
    // Camera Operating Mode
    case Self.iidHomeKitCameraActive: return .bool(homeKitCameraActive)
    case Self.iidEventSnapshotsActive: return .bool(eventSnapshotsActive)
    case Self.iidPeriodicSnapshotsActive: return .bool(periodicSnapshotsActive)
    // Camera Event Recording Management
    case Self.iidRecordingActive: return .int(Int(recordingActive))
    case Self.iidSupportedCameraRecordingConfig:
      return .string(supportedCameraRecordingConfig().base64())
    case Self.iidSupportedVideoRecordingConfig:
      return .string(supportedVideoRecordingConfig().base64())
    case Self.iidSupportedAudioRecordingConfig:
      return .string(supportedAudioRecordingConfig().base64())
    case Self.iidSelectedCameraRecordingConfig:
      if selectedRecordingConfig.isEmpty {
        logger.info("SelectedCameraRecordingConfig read: empty (not yet configured)")
      } else {
        logger.info(
          "SelectedCameraRecordingConfig read: \(self.selectedRecordingConfig.count) bytes")
      }
      return .string(selectedRecordingConfig.base64EncodedString())
    case Self.iidRecordingAudioActive: return .int(Int(recordingAudioActive))
    case Self.iidRTPStreamActive: return .int(Int(rtpStreamActive))
    // Motion Sensor
    case Self.iidMotionDetected: return .bool(isMotionDetected)
    // DataStream Transport Management
    case Self.iidSupportedDataStreamConfig:
      return .string(supportedDataStreamConfig().base64())
    case Self.iidSetupDataStreamTransport:
      return .string(setupDataStreamResponse.base64EncodedString())
    case Self.iidDataStreamVersion: return .string("1.0")
    // Battery
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
    default: return nil
    }
  }

  // MARK: - Write Characteristic

  @discardableResult
  func writeCharacteristic(iid: Int, value: HAPValue, sharedSecret: SharedSecret? = nil) -> Bool {
    switch iid {
    case AccessoryInfoIID.identify:
      identify()
      return true
    case Self.iidSetupEndpoints:
      return handleSetupEndpoints(value)
    case Self.iidSelectedRTPStreamConfig:
      return handleSelectedRTPStreamConfig(value)
    case Self.iidMicrophoneMute:
      switch value {
      case .bool(let v):
        audioSettings.withLock { $0.isMuted = v }
        streamSession?.isMuted = v
        return true
      case .int(let v):
        let muted = v != 0
        audioSettings.withLock { $0.isMuted = muted }
        streamSession?.isMuted = muted
        return true
      default:
        return false
      }
    case Self.iidSpeakerMute:
      switch value {
      case .bool(let v):
        audioSettings.withLock { $0.speakerMuted = v }
        streamSession?.speakerMuted = v
        return true
      case .int(let v):
        let muted = v != 0
        audioSettings.withLock { $0.speakerMuted = muted }
        streamSession?.speakerMuted = muted
        return true
      default:
        return false
      }
    case Self.iidSpeakerVolume:
      if case .int(let v) = value {
        let vol = max(0, min(100, v))
        audioSettings.withLock { $0.speakerVolume = vol }
        streamSession?.speakerVolume = vol
        return true
      }
      return false
    // Camera Operating Mode
    case Self.iidHomeKitCameraActive:
      if let v = boolFromValue(value) {
        homeKitCameraActive = v
        onStateChange?(aid, iid, .bool(v))
        return true
      }
      return false
    case Self.iidEventSnapshotsActive:
      if let v = boolFromValue(value) {
        eventSnapshotsActive = v
        onStateChange?(aid, iid, .bool(v))
        return true
      }
      return false
    case Self.iidPeriodicSnapshotsActive:
      if let v = boolFromValue(value) {
        periodicSnapshotsActive = v
        onStateChange?(aid, iid, .bool(v))
        return true
      }
      return false
    // Camera Event Recording Management
    case Self.iidRecordingActive:
      if let v = intFromValue(value) {
        recordingActive = UInt8(v)
        let isActive = v != 0
        onRecordingConfigChange?(isActive)
        onStateChange?(aid, iid, .int(v))
        // Signal monitoring capture: needed when recording armed + no live stream
        if isActive {
          if streamSession == nil {
            onMonitoringCaptureNeeded?(true)
          }
        } else {
          onMonitoringCaptureNeeded?(false)
        }
        return true
      }
      return false
    case Self.iidSelectedCameraRecordingConfig:
      if case .string(let b64) = value, let data = Data(base64Encoded: b64) {
        logger.info("SelectedCameraRecordingConfig written: \(data.count) bytes")
        selectedRecordingConfig = data
        onSelectedRecordingConfigChange?(data)
        handleSelectedRecordingConfig(data)
        return true
      }
      return false
    case Self.iidRecordingAudioActive:
      if let v = intFromValue(value) {
        recordingAudioActive = UInt8(v)
        onStateChange?(aid, iid, .int(v))
        onRecordingAudioActiveChange?(v != 0)
        return true
      }
      return false
    case Self.iidRTPStreamActive:
      if let v = intFromValue(value) {
        rtpStreamActive = UInt8(v)
        onStateChange?(aid, iid, .int(v))
        return true
      }
      return false
    // DataStream Transport Management
    case Self.iidSetupDataStreamTransport:
      return handleSetupDataStream(value, sharedSecret: sharedSecret)
    default:
      return false
    }
  }

  /// Extract a Bool from either a .bool or .int HAPValue.
  private func boolFromValue(_ value: HAPValue) -> Bool? {
    switch value {
    case .bool(let v): return v
    case .int(let v): return v != 0
    default: return nil
    }
  }

  /// Extract an Int from either a .int or .bool HAPValue.
  /// Handles HomeKit hubs that send JSON `true`/`false` for uint8 characteristics.
  private func intFromValue(_ value: HAPValue) -> Int? {
    switch value {
    case .int(let v): return v
    case .bool(let v): return v ? 1 : 0
    default: return nil
    }
  }

  func identify() {
    logger.info("Camera identify requested")
  }

  /// Update the linked motion sensor (called from VideoMotionDetector).
  func updateMotionDetected(_ detected: Bool) {
    _isMotionDetected.withLock { $0 = detected }
    onStateChange?(aid, Self.iidMotionDetected, .bool(detected))
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

  // MARK: - HKSV Recording Configurations (TLV8)

  /// SupportedCameraRecordingConfiguration
  /// Encoding matches hap-nodejs: flat uint32 prebuffer, 8-byte event trigger options,
  /// container config with nested fragment length.
  func supportedCameraRecordingConfig() -> TLV8.Builder {
    // Media container config
    var containerParams = TLV8.Builder()
    containerParams.add(0x01, uint32: 4000)  // Fragment length 4000ms

    var container = TLV8.Builder()
    container.add(0x01, byte: 0x00)  // Container type: fragmented MP4
    container.add(0x02, tlv: containerParams)  // Container parameters

    var config = TLV8.Builder()
    config.add(0x01, uint32: 4000)  // Prebuffer length: flat 4-byte uint32LE (not nested TLV)
    config.add(0x02, uint64: 1)  // Event trigger options: Motion (bit 0) as 8-byte uint64
    config.add(0x03, tlv: container)  // Media container configuration
    return config
  }

  /// SupportedVideoRecordingConfiguration
  /// Encoding matches hap-nodejs: single CodecParameters blob with independent
  /// profile and level lists (delimited by 00 00), resolution entries also delimited.
  func supportedVideoRecordingConfig() -> TLV8.Builder {
    // Codec parameters: independent lists of profiles and levels with delimiters
    var codecParams = TLV8.Builder()
    codecParams.addList(0x01, bytes: [0x00, 0x01, 0x02])  // Profiles: Baseline, Main, High
    codecParams.addList(0x02, bytes: [0x00, 0x01, 0x02])  // Levels: 3.1, 3.2, 4.0

    // Resolution: 1920x1080 @ 30fps
    var attrs1080 = TLV8.Builder()
    attrs1080.add(0x01, uint16: 1920)
    attrs1080.add(0x02, uint16: 1080)
    attrs1080.add(0x03, byte: 30)

    // Resolution: 1280x720 @ 24fps
    var attrs720 = TLV8.Builder()
    attrs720.add(0x01, uint16: 1280)
    attrs720.add(0x02, uint16: 720)
    attrs720.add(0x03, byte: 24)

    // Video codec configuration
    var codecConfig = TLV8.Builder()
    codecConfig.add(0x01, byte: 0x00)  // CodecType: H.264
    codecConfig.add(0x02, tlv: codecParams)  // Single CodecParameters with lists
    codecConfig.addList(0x03, tlvs: [attrs1080, attrs720])  // Attributes with delimiters

    var config = TLV8.Builder()
    config.add(0x01, tlv: codecConfig)  // VIDEO_CODEC_CONFIGURATION
    return config
  }

  /// SupportedAudioRecordingConfiguration
  /// Recording codec types differ from streaming: AAC-LC = 0, AAC-ELD = 1.
  /// Encoding matches hap-nodejs: sample rates delimited, codec configs delimited.
  func supportedAudioRecordingConfig() -> TLV8.Builder {
    // AAC-ELD codec — preferred by Apple HKSV hubs
    var eldParams = TLV8.Builder()
    eldParams.add(0x01, byte: 1)  // Channels: 1 (mono)
    eldParams.add(0x02, byte: 0)  // BitRate: Variable
    eldParams.addList(0x03, bytes: [1, 2])  // SampleRate: 16kHz, 24kHz (with delimiter)

    var eldConfig = TLV8.Builder()
    eldConfig.add(0x01, byte: 1)  // CodecType: AAC-ELD (recording enum)
    eldConfig.add(0x02, tlv: eldParams)

    // Also offer AAC-LC
    var lcParams = TLV8.Builder()
    lcParams.add(0x01, byte: 1)  // Channels: 1
    lcParams.add(0x02, byte: 0)  // BitRate: Variable
    lcParams.addList(0x03, bytes: [2, 3])  // SampleRate: 24kHz, 32kHz (with delimiter)

    var lcConfig = TLV8.Builder()
    lcConfig.add(0x01, byte: 0)  // CodecType: AAC-LC (recording enum)
    lcConfig.add(0x02, tlv: lcParams)

    var config = TLV8.Builder()
    config.addList(0x01, tlvs: [eldConfig, lcConfig])  // Both codecs with delimiter
    return config
  }

  /// SupportedDataStreamTransportConfiguration
  func supportedDataStreamConfig() -> TLV8.Builder {
    // Transfer transport config: HomeKit Data Stream over TCP
    var transferTransport = TLV8.Builder()
    transferTransport.add(0x01, byte: 0x00)  // Transport type: TCP

    var config = TLV8.Builder()
    config.add(0x01, tlv: transferTransport)
    return config
  }

  /// Generates a default SelectedCameraRecordingConfiguration matching our supported configs.
  /// Used as a fallback when the hub has already written the config in a previous session
  /// but it wasn't persisted.
  func defaultSelectedRecordingConfig() -> Data {
    // General recording config
    var containerParams = TLV8.Builder()
    containerParams.add(0x01, uint32: 4000)  // Fragment length: 4000ms

    var container = TLV8.Builder()
    container.add(0x01, byte: 0x00)  // Container type: fragmented MP4
    container.add(0x02, tlv: containerParams)

    var general = TLV8.Builder()
    general.add(0x01, uint32: 4000)  // Prebuffer length: flat uint32LE
    general.add(0x02, uint64: 1)  // Event trigger: Motion as 8-byte uint64
    general.add(0x03, tlv: container)

    // Video recording config
    var videoCodecParams = TLV8.Builder()
    videoCodecParams.add(0x01, byte: 0x02)  // Profile: High
    videoCodecParams.add(0x02, byte: 0x02)  // Level: 4.0
    videoCodecParams.add(0x03, uint32: 2000)  // Bitrate: 2000 kbps
    videoCodecParams.add(0x04, uint32: 5000)  // I-Frame interval: 5000ms

    var videoAttrs = TLV8.Builder()
    videoAttrs.add(0x01, uint16: 1280)
    videoAttrs.add(0x02, uint16: 720)
    videoAttrs.add(0x03, byte: 24)

    var videoConfig = TLV8.Builder()
    videoConfig.add(0x01, byte: 0x00)  // Codec: H.264
    videoConfig.add(0x02, tlv: videoCodecParams)
    videoConfig.add(0x03, tlv: videoAttrs)

    // Audio recording config
    var audioCodecParams = TLV8.Builder()
    audioCodecParams.add(0x01, byte: 1)  // Channels: 1
    audioCodecParams.add(0x02, byte: 0)  // Bitrate: Variable
    audioCodecParams.add(0x03, byte: 2)  // Sample rate: 24kHz

    var audioConfig = TLV8.Builder()
    audioConfig.add(0x01, byte: 1)  // Codec: AAC-ELD (recording enum)
    audioConfig.add(0x02, tlv: audioCodecParams)

    // Top-level selected config
    var config = TLV8.Builder()
    config.add(0x01, tlv: general)
    config.add(0x02, tlv: videoConfig)
    config.add(0x03, tlv: audioConfig)
    return config.build()
  }

  /// Parse the hub's selected recording configuration.
  private func handleSelectedRecordingConfig(_ data: Data) {
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]
    for (tag, val) in tlvs {
      if tag == 0x01 {
        // Selected general recording configuration
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        for (stag, _) in sub {
          logger.info("Selected recording config tag 0x\(String(stag, radix: 16))")
        }
      } else if tag == 0x02 {
        // Selected video configuration
        logger.info("Selected video recording config: \(val.count) bytes")
      } else if tag == 0x03 {
        // Selected audio configuration
        logger.info("Selected audio recording config: \(val.count) bytes")
      }
    }
  }

  // Pending setup DataStream response.
  // Protected by lock for the same reasons as setupEndpointsResponse.
  private let _setupDataStreamResponse = OSAllocatedUnfairLock(initialState: Data())
  private var setupDataStreamResponse: Data {
    get { _setupDataStreamResponse.withLock { $0 } }
    set { _setupDataStreamResponse.withLock { $0 = newValue } }
  }

  /// Handle DataStream transport setup — placeholder, implemented fully in HAPDataStream.
  private func handleSetupDataStream(_ value: HAPValue, sharedSecret: SharedSecret?) -> Bool {
    guard case .string(let b64) = value, let data = Data(base64Encoded: b64) else { return false }
    logger.info("SetupDataStreamTransport: \(data.count) bytes")
    // Full implementation in Phase 5 (HAPDataStream.swift)
    onSetupDataStream?(
      data,
      sharedSecret,
      { [weak self] response in
        self?.setupDataStreamResponse = response
      })
    return true
  }

  /// Callback for DataStream setup — set by HAPDataStream.
  var onSetupDataStream:
    ((_ request: Data, _ sharedSecret: SharedSecret?, _ respond: @escaping (Data) -> Void) -> Void)? {
    get { _callbacks.withLock { $0.onSetupDataStream } }
    set { _callbacks.withLock { $0.onSetupDataStream = newValue } }
  }

  // MARK: - Streaming Status

  private func streamingStatusTLV() -> Data {
    var b = TLV8.Builder()
    let status: UInt8 = streamSession != nil ? 1 : 0  // 0=Available, 1=InUse, 2=Unavailable
    b.add(0x01, byte: status)
    return b.build()
  }

  // MARK: - Setup Endpoints

  private func handleSetupEndpoints(_ value: HAPValue) -> Bool {
    guard case .string(let b64) = value, let data = Data(base64Encoded: b64) else { return false }
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

    // Stop any existing stream session before creating a new one
    streamSession?.stopStreaming()
    streamSession = nil

    let videoSSRC = UInt32.random(in: 1...UInt32.max)
    let audioSSRC = UInt32.random(in: 1...UInt32.max)

    // Determine local IP address — must be on the same subnet as the controller
    let localAddress = Self.localIPAddress(matching: controllerAddress) ?? "0.0.0.0"

    // Allocate UDP ports — video uses N (RTP) and N+1 (RTCP),
    // audio uses N+2 (RTP) and N+3 (RTCP). Reserve room for all four ports.
    let videoPort: UInt16 = UInt16.random(in: 50000...59994)
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

  private func handleSelectedRTPStreamConfig(_ value: HAPValue) -> Bool {
    guard case .string(let b64) = value, let data = Data(base64Encoded: b64) else { return false }
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

        case 0:  // END
          logger.info("Stream STOP requested")
          stopStreaming()
        case 2:  // RECONFIGURE — not fully implemented; stop stream as fallback
          logger.warning("Stream RECONFIGURE not implemented — stopping stream")
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
      switch DeviceOrientation.current {
      case .landscapeLeft: return (0, false)
      case .landscapeRight: return (180, false)
      case .portraitUpsideDown: return (270, true)
      default: return (90, true)  // portrait / unknown / faceUp / faceDown
      }
    #else
      return (0, false)  // macOS — no rotation needed
    #endif
  }

  /// The resolved camera device for external callers (e.g. MonitoringCaptureSession).
  var resolvedCamera: AVCaptureDevice? { resolveCamera() }

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

    let settings = audioSettings.withLock { $0 }
    session.isMuted = settings.isMuted
    session.speakerMuted = settings.speakerMuted
    session.speakerVolume = settings.speakerVolume
    session.videoMotionDetector = videoMotionDetector
    session.onSnapshotFrame = { [weak self] jpeg in
      self?.cachedSnapshot = jpeg
    }

    // Stop monitoring capture — live stream takes over motion detection.
    // fMP4 prebuffering pauses because the live stream encodes at a different
    // resolution that doesn't match the init segment.
    onMonitoringCaptureNeeded?(false)

    let effectiveBitrate = max(bitrate, minimumBitrate)
    let rotation = currentRotation()
    logger.info(
      "Bitrate: negotiated=\(bitrate)kbps, minimum=\(self.minimumBitrate)kbps, effective=\(effectiveBitrate)kbps, rotation=\(rotation.angle)°"
    )
    session.startStreaming(
      width: width, height: height, fps: fps, bitrate: effectiveBitrate, payloadType: payloadType,
      audioPayloadType: audioPayloadType, camera: camera, rotationAngle: rotation.angle,
      swapDimensions: rotation.swapDimensions)
    onStateChange?(
      aid, Self.iidStreamingStatus, .string(streamingStatusTLV().base64EncodedString()))
  }

  private func stopStreaming() {
    streamSession?.stopStreaming()
    streamSession = nil
    onStateChange?(
      aid, Self.iidStreamingStatus, .string(streamingStatusTLV().base64EncodedString()))
    // Resume monitoring capture if recording is still armed
    if recordingActive != 0 {
      onMonitoringCaptureNeeded?(true)
    }
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

    // Pause other capture sessions (e.g. monitoring session) — iOS only
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
    let grabber = FrameGrabber(framesToSkip: 10, context: snapshotCIContext)
    let queue = DispatchQueue(label: "me.fausak.taylor.Pylo.snapshot", qos: .userInteractive)
    videoOutput.setSampleBufferDelegate(grabber, queue: queue)

    session.startRunning()
    defer { session.stopRunning() }

    // Wait up to 3 seconds for a usable frame
    _ = grabber.waitForCapture(timeout: .now() + 3)

    guard let cgImage = grabber.capturedImage else {
      logger.warning("Frame grab timed out — returning cached snapshot")
      return cachedSnapshot
    }

    let ciImage = CIImage(cgImage: cgImage)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let jpeg = snapshotCIContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:])
    else { return cachedSnapshot }

    cachedSnapshot = jpeg
    return jpeg
  }

  // MARK: - JSON Serialization

  func toJSON() -> [String: Any] {
    // Camera RTP Stream Management — conditionally include Active for HKSV
    var rtpCharacteristics: [[String: Any]] = [
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
    ]
    if hksvEnabled {
      rtpCharacteristics.append([
        "iid": Self.iidRTPStreamActive,
        "type": Self.uuidActive, "format": "uint8",
        "perms": ["pr", "pw", "ev"], "value": recordingActive,
        "minValue": 0, "maxValue": 1,
      ])
    }

    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      // Camera RTP Stream Management Service
      [
        "iid": Self.iidCameraService,
        "type": Self.uuidCameraRTPStreamManagement,
        "characteristics": rtpCharacteristics,
      ],
      // Microphone Service
      [
        "iid": Self.iidMicrophoneService,
        "type": Self.uuidMicrophone,
        "characteristics": [
          [
            "iid": Self.iidMicrophoneMute,
            "type": Self.uuidMute, "format": "bool",
            "perms": ["pr", "pw", "ev"], "value": audioSettings.withLock { $0.isMuted },
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
            "perms": ["pr", "pw", "ev"], "value": audioSettings.withLock { $0.speakerMuted },
          ],
          [
            "iid": Self.iidSpeakerVolume,
            "type": Self.uuidVolume, "format": "uint8",
            "perms": ["pr", "pw", "ev"], "value": audioSettings.withLock { $0.speakerVolume },
            "minValue": 0, "maxValue": 100, "minStep": 1,
          ],
        ],
      ],
    ]

    // HKSV services (only if enabled)
    if hksvEnabled {
      // Camera Operating Mode Service
      services.append([
        "iid": Self.iidOperatingModeService,
        "type": Self.uuidCameraOperatingMode,
        "characteristics": [
          [
            "iid": Self.iidHomeKitCameraActive,
            "type": Self.uuidHomeKitCameraActive, "format": "bool",
            "perms": ["pr", "pw", "ev"], "value": homeKitCameraActive,
          ],
          [
            "iid": Self.iidEventSnapshotsActive,
            "type": Self.uuidEventSnapshotsActive, "format": "bool",
            "perms": ["pr", "pw", "ev"], "value": eventSnapshotsActive,
          ],
          [
            "iid": Self.iidPeriodicSnapshotsActive,
            "type": Self.uuidPeriodicSnapshotsActive, "format": "bool",
            "perms": ["pr", "pw", "ev"], "value": periodicSnapshotsActive,
          ],
        ],
      ])

      // Camera Event Recording Management Service
      services.append([
        "iid": Self.iidRecordingManagementService,
        "type": Self.uuidCameraEventRecordingManagement,
        "linked": [Self.iidCameraService, Self.iidMotionSensorService, Self.iidDataStreamService],
        "characteristics": [
          [
            "iid": Self.iidRecordingActive,
            "type": Self.uuidActive, "format": "uint8",
            "perms": ["pr", "pw", "ev"], "value": recordingActive,
            "minValue": 0, "maxValue": 1,
          ],
          [
            "iid": Self.iidSupportedCameraRecordingConfig,
            "type": Self.uuidSupportedCameraRecordingConfig, "format": "tlv8",
            "perms": ["pr", "ev"],
            "value": supportedCameraRecordingConfig().base64(),
          ],
          [
            "iid": Self.iidSupportedVideoRecordingConfig,
            "type": Self.uuidSupportedVideoRecordingConfig, "format": "tlv8",
            "perms": ["pr", "ev"],
            "value": supportedVideoRecordingConfig().base64(),
          ],
          [
            "iid": Self.iidSupportedAudioRecordingConfig,
            "type": Self.uuidSupportedAudioRecordingConfig, "format": "tlv8",
            "perms": ["pr", "ev"],
            "value": supportedAudioRecordingConfig().base64(),
          ],
          [
            "iid": Self.iidSelectedCameraRecordingConfig,
            "type": Self.uuidSelectedCameraRecordingConfig, "format": "tlv8",
            "perms": ["pr", "pw", "ev"],
            "value": selectedRecordingConfig.base64EncodedString(),
          ],
          [
            "iid": Self.iidRecordingAudioActive,
            "type": Self.uuidRecordingAudioActive, "format": "uint8",
            "perms": ["pr", "pw", "ev"], "value": recordingAudioActive,
            "minValue": 0, "maxValue": 1,
          ],
        ],
      ])

      // Motion Sensor Service (linked to recording management)
      services.append([
        "iid": Self.iidMotionSensorService,
        "type": Self.uuidMotionSensor,
        "characteristics": [
          [
            "iid": Self.iidMotionDetected,
            "type": Self.uuidMotionDetected, "format": "bool",
            "perms": ["pr", "ev"], "value": isMotionDetected,
          ]
        ],
      ])

      // DataStream Transport Management Service
      services.append([
        "iid": Self.iidDataStreamService,
        "type": Self.uuidDataStreamTransportManagement,
        "characteristics": [
          [
            "iid": Self.iidSupportedDataStreamConfig,
            "type": Self.uuidSupportedDataStreamTransportConfig, "format": "tlv8",
            "perms": ["pr"],
            "value": supportedDataStreamConfig().base64(),
          ],
          [
            "iid": Self.iidSetupDataStreamTransport,
            "type": Self.uuidSetupDataStreamTransport, "format": "tlv8",
            "perms": ["pr", "pw", "wr"],
            "value": setupDataStreamResponse.base64EncodedString(),
          ],
          [
            "iid": Self.iidDataStreamVersion,
            "type": Self.uuidVersion, "format": "string",
            "perms": ["pr"], "value": "1.0",
          ],
        ],
      ])
    }

    if let battery = batteryServiceJSON(state: batteryState) {
      services.append(battery)
    }
    return ["aid": aid, "services": services]
  }
}

// MARK: - Frame Grabber (for silent snapshots)

private nonisolated final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate
{
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
    // Render to CGImage immediately while the pixel buffer is still valid —
    // CIImage(cvPixelBuffer:) only holds a lazy reference and the pool may
    // recycle the backing memory after this callback returns.
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    lock.withLock { _capturedImage = cgImage }
    semaphore.signal()
  }
}

// MARK: - Device Orientation Cache

/// Thread-safe cache for UIDevice orientation, updated via NotificationCenter.
/// UIDevice.current.orientation is safe to read from any thread (backed by an
/// atomic internal property), but UIKit marks it @MainActor. Rather than
/// suppressing the warning, we observe orientation-change notifications on
/// MainActor and cache the value atomically for any-thread reads.
#if os(iOS)
  private nonisolated enum DeviceOrientation {
    private static let state = OSAllocatedUnfairLock(
      initialState: Int(UIDeviceOrientation.portrait.rawValue)
    )

    private static let token: NSObjectProtocol =
      NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification,
        object: nil,
        queue: .main
      ) { _ in
        let raw = MainActor.assumeIsolated { UIDevice.current.orientation.rawValue }
        state.withLock { $0 = raw }
      }

    /// Current device orientation, safe to read from any thread.
    /// Lazily registers a notification observer on first access.
    static var current: UIDeviceOrientation {
      _ = token
      return UIDeviceOrientation(rawValue: state.withLock { $0 }) ?? .portrait
    }
  }
#endif
