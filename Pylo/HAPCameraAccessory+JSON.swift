import Foundation
import HAP
import Locked
import TLV8
import os

// MARK: - JSON Serialization

extension HAPCameraAccessory {

  func toJSON() -> [String: Any] {
    // Snapshot HKSV state once to avoid holding the lock during serialization.
    let hksv = hksvState.value

    // Camera RTP Stream Management -- conditionally include Active for HKSV
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
        "perms": ["pr", "pw", "ev"], "value": hksv.rtpStreamActive,
        "minValue": 0, "maxValue": 1,
      ])
    }

    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      protocolInformationServiceJSON(),
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
            "perms": ["pr", "pw", "ev"], "value": hksv.homeKitCameraActive,
          ],
          [
            "iid": Self.iidEventSnapshotsActive,
            "type": Self.uuidEventSnapshotsActive, "format": "bool",
            "perms": ["pr", "pw", "ev"], "value": hksv.eventSnapshotsActive,
          ],
          [
            "iid": Self.iidPeriodicSnapshotsActive,
            "type": Self.uuidPeriodicSnapshotsActive, "format": "bool",
            "perms": ["pr", "pw", "ev"], "value": hksv.periodicSnapshotsActive,
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
            "perms": ["pr", "pw", "ev"], "value": hksv.recordingActive,
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
            "value": hksv.selectedRecordingConfig.base64EncodedString(),
          ],
          [
            "iid": Self.iidRecordingAudioActive,
            "type": Self.uuidRecordingAudioActive, "format": "uint8",
            "perms": ["pr", "pw", "ev"], "value": hksv.recordingAudioActive,
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
          ],
          [
            "iid": Self.iidMotionSensorStatusActive,
            "type": Self.uuidStatusActive, "format": "bool",
            "perms": ["pr", "ev"], "value": hksv.homeKitCameraActive,
          ],
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

    if let battery = batteryServiceJSON(state: batteryState) { services.append(battery) }
    return ["aid": aid, "services": services]
  }
}
