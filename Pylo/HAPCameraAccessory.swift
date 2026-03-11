@preconcurrency import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import FragmentedMP4
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
    let deviceTypes: [AVCaptureDevice.DeviceType] = [
      .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
    ]
    // Query each position separately and merge — some devices (e.g. iPhone 6s)
    // may not return the front camera when using position: .unspecified.
    var seen = Set<String>()
    var cameras = [CameraOption]()
    for position in [AVCaptureDevice.Position.back, .front] {
      let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: deviceTypes,
        mediaType: .video,
        position: position
      )
      for device in discovery.devices where seen.insert(device.uniqueID).inserted {
        cameras.append(
          CameraOption(
            id: device.uniqueID,
            name: device.localizedName,
            fNumber: device.lensAperture
          ))
      }
    }
    return cameras
  }
}

// MARK: - Camera Accessory

/// HAP camera sub-accessory exposing CameraRTPStreamManagement.
/// Handles the full pipeline: TLV8 negotiation -> video capture -> H.264 -> RTP -> SRTP -> UDP.
nonisolated final class HAPCameraAccessory: HAPAccessoryProtocol, HAPSnapshotProvider,
  @unchecked Sendable
{

  let aid: Int
  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String

  private let _onStateChange = Locked<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state -- nil means no battery, omit battery service.
  private let _batteryState = Locked<BatteryState?>(initialState: nil)
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
    var onMonitoringCaptureNeeded: ((_ needed: Bool, _ existingSession: AVCaptureSession?) -> Void)?
    var onMonitoringSessionHandoff: (() -> AVCaptureSession?)?
    var onStreamingStart: (() -> Void)?
    var onVideoMotionChange: ((Bool) -> Void)?
    var onRecordingConfigChange: ((_ active: Bool) -> Void)?
    var onRecordingAudioActiveChange: ((_ active: Bool) -> Void)?
    var onSelectedRecordingConfigChange: ((_ config: Data) -> Void)?
    var onSetupDataStream:
      (
        (_ requestData: Data, _ sharedSecret: SharedSecret?, _ respond: @escaping (Data) -> Void) ->
          Void
      )?
  }
  private let _callbacks = Locked(initialState: Callbacks())

  var onSnapshotWillCapture: (() -> Void)? {
    get { _callbacks.withLock { $0.onSnapshotWillCapture } }
    set { _callbacks.withLock { $0.onSnapshotWillCapture = newValue } }
  }
  var onSnapshotDidCapture: (() -> Void)? {
    get { _callbacks.withLock { $0.onSnapshotDidCapture } }
    set { _callbacks.withLock { $0.onSnapshotDidCapture = newValue } }
  }
  var onMonitoringCaptureNeeded: ((_ needed: Bool, _ existingSession: AVCaptureSession?) -> Void)? {
    get { _callbacks.withLock { $0.onMonitoringCaptureNeeded } }
    set { _callbacks.withLock { $0.onMonitoringCaptureNeeded = newValue } }
  }
  var onMonitoringSessionHandoff: (() -> AVCaptureSession?)? {
    get { _callbacks.withLock { $0.onMonitoringSessionHandoff } }
    set { _callbacks.withLock { $0.onMonitoringSessionHandoff = newValue } }
  }
  var onStreamingStart: (() -> Void)? {
    get { _callbacks.withLock { $0.onStreamingStart } }
    set { _callbacks.withLock { $0.onStreamingStart = newValue } }
  }
  var onVideoMotionChange: ((Bool) -> Void)? {
    get { _callbacks.withLock { $0.onVideoMotionChange } }
    set { _callbacks.withLock { $0.onVideoMotionChange = newValue } }
  }

  /// Whether video motion detection is active on the streaming session.
  var videoMotionEnabled: Bool {
    get { streamState.withLock { $0.videoMotionEnabled } }
    set {
      // Allocate detector outside the lock to avoid heavy work while locked.
      let detector: VideoMotionDetector? = newValue ? VideoMotionDetector() : nil
      detector?.onMotionChange = { [weak self] detected in
        self?.onVideoMotionChange?(detected)
      }
      streamState.withLock { s in
        s.videoMotionEnabled = newValue
        if newValue {
          s.videoMotionDetector = detector
          s.streamSession?.videoMotionDetector = detector
        } else {
          s.videoMotionDetector?.reset()
          s.videoMotionDetector = nil
          s.streamSession?.videoMotionDetector = nil
        }
      }
    }
  }

  /// Lock-protected streaming state accessed from multiple queues.
  private struct StreamState {
    var videoMotionDetector: VideoMotionDetector?
    var ambientLightDetector: AmbientLightDetector?
    var streamSession: CameraStreamSession?
    var videoMotionEnabled: Bool = false
  }
  private let streamState = Locked(initialState: StreamState())
  var videoMotionDetector: VideoMotionDetector? {
    get { streamState.withLock { $0.videoMotionDetector } }
    set { streamState.withLock { $0.videoMotionDetector = newValue } }
  }
  var ambientLightDetector: AmbientLightDetector? {
    get { streamState.withLock { $0.ambientLightDetector } }
    set { streamState.withLock { $0.ambientLightDetector = newValue } }
  }

  let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Camera")

  /// Reusable CIContext for snapshot JPEG encoding (CIContext is expensive to allocate).
  let snapshotCIContext = CIContext()

  /// Which camera to use for streaming and snapshots (nil = default back wide-angle).
  /// Written once during setup before the server starts. Not locked because
  /// no concurrent access occurs — the server queue is not active during setup.
  var selectedCameraID: String?

  /// Minimum bitrate (kbps) to use regardless of what the controller negotiates.
  /// Written once during setup before the server starts. Not locked because
  /// no concurrent access occurs — the server queue is not active during setup.
  var minimumBitrate: Int = 0

  /// Whether microphone audio is enabled (user preference). When false, capture sessions
  /// skip mic input entirely. Written from MainActor, read from the server queue during
  /// stream/monitoring setup. Protected by a lock to avoid a data race.
  private let _microphoneEnabled = Locked(initialState: false)
  var microphoneEnabled: Bool {
    get { _microphoneEnabled.withLock { $0 } }
    set { _microphoneEnabled.withLock { $0 = newValue } }
  }

  /// Active streaming session (nil when idle).
  var streamSession: CameraStreamSession? {
    get { streamState.withLock { $0.streamSession } }
    set { streamState.withLock { $0.streamSession = newValue } }
  }

  /// Most recent JPEG snapshot captured during streaming (used as fallback for snapshot requests).
  /// Protected by a lock because it is written from captureQueue (via onSnapshotFrame) and from
  /// a global queue (captureSnapshot), and read from the server queue.
  private let _cachedSnapshot = Locked<
    (data: Data, timestamp: TimeInterval)?
  >(initialState: nil)
  var cachedSnapshot: Data? {
    get { _cachedSnapshot.withLock { $0?.data } }
    set {
      let now = ProcessInfo.processInfo.systemUptime
      _cachedSnapshot.withLock { $0 = newValue.map { (data: $0, timestamp: now) } }
    }
  }
  /// Returns the cached snapshot only if it was captured within the given max age in seconds.
  func cachedSnapshot(maxAgeSeconds: TimeInterval) -> Data? {
    let now = ProcessInfo.processInfo.systemUptime
    return _cachedSnapshot.withLock { cached in
      guard let cached, (now - cached.timestamp) < maxAgeSeconds else { return nil }
      return cached.data
    }
  }

  /// Audio settings accessed from the server queue (read/write characteristics)
  /// and from CameraStreamSession (on capture/rtp queues).
  struct AudioSettings {
    var isMuted: Bool = false
    var speakerMuted: Bool = false
    var speakerVolume: Int = 100
  }
  let audioSettings = Locked(initialState: AudioSettings())

  // MARK: - HKSV State

  /// HKSV-related state accessed from the server queue (read/write characteristics)
  /// and from toJSON() / stopStreaming(). Protected by an unfair lock.
  struct HKSVState {
    var homeKitCameraActive: Bool = true
    var eventSnapshotsActive: Bool = true
    var periodicSnapshotsActive: Bool = true
    var recordingActive: UInt8 = 0  // 0=disabled, 1=enabled
    var recordingAudioActive: UInt8 = 0
    var selectedRecordingConfig = Data()
    var rtpStreamActive: UInt8 = 1
  }
  let hksvState = Locked(initialState: HKSVState())

  /// Convenience read-only accessors that read through the lock.
  /// `periodicSnapshotsActive` and `eventSnapshotsActive` also satisfy `HAPSnapshotProvider`.
  var homeKitCameraActive: Bool { hksvState.withLock { $0.homeKitCameraActive } }
  var periodicSnapshotsActive: Bool { hksvState.withLock { $0.periodicSnapshotsActive } }
  var eventSnapshotsActive: Bool { hksvState.withLock { $0.eventSnapshotsActive } }
  var recordingActive: UInt8 { hksvState.withLock { $0.recordingActive } }
  var recordingAudioActive: UInt8 { hksvState.withLock { $0.recordingAudioActive } }
  var selectedRecordingConfig: Data { hksvState.withLock { $0.selectedRecordingConfig } }
  var rtpStreamActive: UInt8 { hksvState.withLock { $0.rtpStreamActive } }

  /// Restores `recordingActive` from persisted state without triggering callbacks.
  /// Must be called before wiring `onRecordingConfigChange` / `onMonitoringCaptureNeeded`.
  func restoreRecordingActive(_ value: UInt8) {
    hksvState.withLock { $0.recordingActive = value }
  }

  /// Restores `recordingAudioActive` from persisted state without triggering callbacks.
  func restoreRecordingAudioActive(_ value: UInt8) {
    hksvState.withLock { $0.recordingAudioActive = value }
  }

  /// Restores `selectedRecordingConfig` from persisted state.
  func restoreSelectedRecordingConfig(_ data: Data) {
    hksvState.withLock { $0.selectedRecordingConfig = data }
  }

  /// Shared fMP4 writer for HKSV pre-buffering.  Set by the host so it can be
  /// forwarded to `CameraStreamSession` during live streams.
  /// Written once during setup before the server starts. Not locked because
  /// no concurrent access occurs — the server queue is not active during setup.
  var fragmentWriter: FragmentedMP4Writer?

  /// Motion sensor state (linked to this camera accessory)
  private let _isMotionDetected = Locked(initialState: false)
  var isMotionDetected: Bool {
    _isMotionDetected.withLock { $0 }
  }

  /// Whether HKSV services are enabled on this accessory.
  /// Written once during setup before the server starts. Not locked because
  /// no concurrent access occurs — the server queue is not active during setup.
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

  // Pending setup endpoint response (written by controller, read back after).
  // Protected by lock since writes happen from the server queue and snapshot
  // capture can trigger handleSetupEndpoints from another queue.
  let _setupEndpointsResponse = Locked(initialState: Data())
  var setupEndpointsResponse: Data {
    get { _setupEndpointsResponse.withLock { $0 } }
    set { _setupEndpointsResponse.withLock { $0 = newValue } }
  }

  // Pending setup DataStream response.
  // Protected by lock for the same reasons as setupEndpointsResponse.
  let _setupDataStreamResponse = Locked(initialState: Data())
  var setupDataStreamResponse: Data {
    get { _setupDataStreamResponse.withLock { $0 } }
    set { _setupDataStreamResponse.withLock { $0 = newValue } }
  }

  /// Callback for DataStream setup -- set by HAPDataStream.
  var onSetupDataStream:
    ((_ request: Data, _ sharedSecret: SharedSecret?, _ respond: @escaping (Data) -> Void) -> Void)?
  {
    get { _callbacks.withLock { $0.onSetupDataStream } }
    set { _callbacks.withLock { $0.onSetupDataStream = newValue } }
  }

  init(
    aid: Int,
    name: String = "Pylo Camera",
    model: String = "iPhone Camera",
    manufacturer: String = "Pylo",
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

  // Motion Sensor linked to camera (iid 50-52)
  static let iidMotionSensorService = 50
  static let iidMotionDetected = 51
  static let iidMotionSensorStatusActive = 52

  // DataStream Transport Management Service (iid 60-62)
  static let iidDataStreamService = 60
  static let iidSupportedDataStreamConfig = 61
  static let iidSetupDataStreamTransport = 62
  static let iidDataStreamVersion = 63

  // MARK: - HAP UUIDs (from HomeKit framework constants)

  static let uuidCameraRTPStreamManagement = HKServiceUUID.cameraRTPStreamManagement
  static let uuidSupportedVideoStreamConfig = HKCharacteristicUUID.supportedVideoStreamConfig
  static let uuidSupportedAudioStreamConfig = HKCharacteristicUUID.supportedAudioStreamConfig
  static let uuidSupportedRTPConfig = HKCharacteristicUUID.supportedRTPConfig
  static let uuidSelectedRTPStreamConfig = HKCharacteristicUUID.selectedRTPStreamConfig
  static let uuidSetupEndpoints = HKCharacteristicUUID.setupEndpoints
  static let uuidStreamingStatus = HKCharacteristicUUID.streamingStatus
  static let uuidMicrophone = HKServiceUUID.microphone
  static let uuidSpeaker = HKServiceUUID.speaker
  static let uuidMute = HKCharacteristicUUID.mute
  static let uuidVolume = HKCharacteristicUUID.volume
  static let uuidActive = HKCharacteristicUUID.active

  // Camera Operating Mode UUIDs (HKSV — no public HomeKit constants)
  static let uuidCameraOperatingMode = "21A"
  static let uuidHomeKitCameraActive = "21B"
  static let uuidEventSnapshotsActive = "223"
  static let uuidPeriodicSnapshotsActive = "225"

  // Camera Event Recording Management UUIDs (HKSV — no public HomeKit constants)
  static let uuidCameraEventRecordingManagement = "204"
  static let uuidSupportedCameraRecordingConfig = "205"
  static let uuidSupportedVideoRecordingConfig = "206"
  static let uuidSupportedAudioRecordingConfig = "207"
  static let uuidSelectedCameraRecordingConfig = "209"
  static let uuidRecordingAudioActive = "226"

  // Motion Sensor UUIDs
  static let uuidMotionSensor = HKServiceUUID.motionSensor
  static let uuidMotionDetected = HKCharacteristicUUID.motionDetected
  static let uuidStatusActive = "75"

  // DataStream Transport Management UUIDs (no public HomeKit constants)
  static let uuidDataStreamTransportManagement = "129"
  static let uuidSupportedDataStreamTransportConfig = "130"
  static let uuidSetupDataStreamTransport = "131"
  static let uuidVersion = HKCharacteristicUUID.version

  // MARK: - Read Characteristic

  func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case ProtocolInfoIID.version: return .string(hapProtocolVersion)
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
    case Self.iidHomeKitCameraActive: return .bool(hksvState.withLock { $0.homeKitCameraActive })
    case Self.iidEventSnapshotsActive: return .bool(hksvState.withLock { $0.eventSnapshotsActive })
    case Self.iidPeriodicSnapshotsActive:
      return .bool(hksvState.withLock { $0.periodicSnapshotsActive })
    // Camera Event Recording Management
    case Self.iidRecordingActive: return .int(Int(hksvState.withLock { $0.recordingActive }))
    case Self.iidSupportedCameraRecordingConfig:
      return .string(supportedCameraRecordingConfig().base64())
    case Self.iidSupportedVideoRecordingConfig:
      return .string(supportedVideoRecordingConfig().base64())
    case Self.iidSupportedAudioRecordingConfig:
      return .string(supportedAudioRecordingConfig().base64())
    case Self.iidSelectedCameraRecordingConfig:
      let config = hksvState.withLock { $0.selectedRecordingConfig }
      if config.isEmpty {
        logger.info("SelectedCameraRecordingConfig read: empty (not yet configured)")
      } else {
        logger.info("SelectedCameraRecordingConfig read: \(config.count) bytes")
      }
      return .string(config.base64EncodedString())
    case Self.iidRecordingAudioActive:
      return .int(Int(hksvState.withLock { $0.recordingAudioActive }))
    case Self.iidRTPStreamActive: return .int(Int(hksvState.withLock { $0.rtpStreamActive }))
    // Motion Sensor
    case Self.iidMotionDetected: return .bool(isMotionDetected)
    case Self.iidMotionSensorStatusActive:
      return .bool(hksvState.withLock { $0.homeKitCameraActive })
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
        hksvState.withLock { $0.homeKitCameraActive = v }
        onStateChange?(aid, iid, .bool(v))
        // Mirror to motion sensor StatusActive (HAP-NodeJS convention)
        onStateChange?(aid, Self.iidMotionSensorStatusActive, .bool(v))
        return true
      }
      return false
    case Self.iidEventSnapshotsActive:
      if let v = boolFromValue(value) {
        hksvState.withLock { $0.eventSnapshotsActive = v }
        onStateChange?(aid, iid, .bool(v))
        return true
      }
      return false
    case Self.iidPeriodicSnapshotsActive:
      if let v = boolFromValue(value) {
        hksvState.withLock { $0.periodicSnapshotsActive = v }
        onStateChange?(aid, iid, .bool(v))
        return true
      }
      return false
    // Camera Event Recording Management
    case Self.iidRecordingActive:
      if let v = intFromValue(value) {
        hksvState.withLock { $0.recordingActive = UInt8(v) }
        let isActive = v != 0
        onRecordingConfigChange?(isActive)
        onStateChange?(aid, iid, .int(v))
        // Signal monitoring capture: needed when recording armed + no live stream
        if isActive {
          if streamSession == nil {
            onMonitoringCaptureNeeded?(true, nil)
          }
        } else {
          onMonitoringCaptureNeeded?(false, nil)
        }
        return true
      }
      return false
    case Self.iidSelectedCameraRecordingConfig:
      if case .string(let b64) = value, let data = Data(base64Encoded: b64) {
        logger.info("SelectedCameraRecordingConfig written: \(data.count) bytes")
        hksvState.withLock { $0.selectedRecordingConfig = data }
        onSelectedRecordingConfigChange?(data)
        handleSelectedRecordingConfig(data)
        return true
      }
      return false
    case Self.iidRecordingAudioActive:
      if let v = intFromValue(value) {
        hksvState.withLock { $0.recordingAudioActive = UInt8(v) }
        onStateChange?(aid, iid, .int(v))
        onRecordingAudioActiveChange?(v != 0)
        return true
      }
      return false
    case Self.iidRTPStreamActive:
      if let v = intFromValue(value) {
        hksvState.withLock { $0.rtpStreamActive = UInt8(v) }
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

  // MARK: - Streaming Control

  /// Returns (videoRotationAngle, shouldSwapDimensions) based on current device orientation.
  /// The camera sensor's native orientation is landscape-left, so portrait requires a 90 degree rotation.
  func currentRotation() -> (angle: Int, swapDimensions: Bool) {
    #if os(iOS)
      switch DeviceOrientation.current {
      case .landscapeLeft: return (0, false)
      case .landscapeRight: return (180, false)
      case .portraitUpsideDown: return (270, true)
      default: return (90, true)  // portrait / unknown / faceUp / faceDown
      }
    #else
      return (0, false)  // macOS -- no rotation needed
    #endif
  }

  /// The resolved camera device for external callers (e.g. MonitoringCaptureSession).
  var resolvedCamera: AVCaptureDevice? { resolveCamera() }
}

// MARK: - Device Orientation Cache

/// Thread-safe cache for UIDevice orientation, updated via NotificationCenter.
/// UIDevice.current.orientation is safe to read from any thread (backed by an
/// atomic internal property), but UIKit marks it @MainActor. Rather than
/// suppressing the warning, we observe orientation-change notifications on
/// MainActor and cache the value atomically for any-thread reads.
#if os(iOS)
  // Uses the shared DeviceOrientationCache defined below.
  private typealias DeviceOrientation = DeviceOrientationCache
#endif

// MARK: - Shared Device Orientation Cache

/// Thread-safe device orientation cache. Observes orientation-change notifications
/// on MainActor and caches the value atomically for any-thread reads.
/// Shared by HAPCameraAccessory and MonitoringCaptureSession to avoid duplicate observers.
#if os(iOS)
  nonisolated enum DeviceOrientationCache {
    private static let state = Locked(
      initialState: Int(UIDeviceOrientation.portrait.rawValue)
    )

    private static let token: NSObjectProtocol = {
      return NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification,
        object: nil,
        queue: .main
      ) { _ in
        let orientation = MainActor.assumeIsolated { UIDevice.current.orientation }
        // Ignore flat and unknown orientations so the cache retains the last
        // meaningful value. iPads in stands commonly report .faceUp which would
        // otherwise be treated as portrait, causing upside-down streams (#40).
        guard orientation != .faceUp, orientation != .faceDown,
          orientation != .unknown
        else { return }
        state.withLock { $0 = orientation.rawValue }
      }
    }()

    /// Seed the cache with the current orientation. Must be called from
    /// MainActor (e.g. in App.init) before any background access to `current`.
    /// This is separated from the lazy `token` initializer so that the token
    /// itself is safe to initialize from any thread.
    @MainActor
    static func seed() {
      _ = token
      let initial = UIDevice.current.orientation
      if initial != .unknown, initial != .faceUp, initial != .faceDown {
        state.withLock { $0 = initial.rawValue }
      }
    }

    /// Current device orientation, safe to read from any thread.
    /// Lazily registers a notification observer on first access.
    static var current: UIDeviceOrientation {
      _ = token
      return UIDeviceOrientation(rawValue: state.withLock { $0 }) ?? .portrait
    }
  }
#endif
