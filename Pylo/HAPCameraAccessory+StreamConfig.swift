import Foundation
import TLV8
import os

// MARK: - Supported Configurations (static TLV8 blobs)

extension HAPCameraAccessory {

  /// SupportedVideoStreamConfiguration TLV8
  func supportedVideoConfig() -> TLV8.Builder {
    // H.264 codec parameters: Constrained Baseline profile, Level 3.1
    var codecParams = TLV8.Builder()
    codecParams.add(0x01, byte: 0x00)  // ProfileID: Constrained Baseline
    codecParams.add(0x02, byte: 0x00)  // Level: 3.1
    codecParams.add(0x03, byte: 0x00)  // Packetization: Non-interleaved

    // Video codec config
    var codecConfig = TLV8.Builder()
    codecConfig.add(0x01, byte: 0x00)  // CodecType: H.264
    codecConfig.add(0x02, tlv: codecParams)

    // Add each advertised resolution at the configured frame rate
    for res in maxResolution.advertisedResolutions {
      var attrs = TLV8.Builder()
      attrs.add(0x01, uint16: UInt16(res.width))
      attrs.add(0x02, uint16: UInt16(res.height))
      attrs.add(0x03, byte: UInt8(frameRate.rawValue))
      codecConfig.add(0x03, tlv: attrs)
    }

    // Always advertise a low resolution for Apple Watch / widget thumbnails
    var attrs240 = TLV8.Builder()
    attrs240.add(0x01, uint16: 320)
    attrs240.add(0x02, uint16: 240)
    attrs240.add(0x03, byte: 15)
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

    // Add each advertised resolution at the configured frame rate
    var resTLVs: [TLV8.Builder] = []
    for res in maxResolution.advertisedResolutions {
      var attrs = TLV8.Builder()
      attrs.add(0x01, uint16: UInt16(res.width))
      attrs.add(0x02, uint16: UInt16(res.height))
      attrs.add(0x03, byte: UInt8(frameRate.rawValue))
      resTLVs.append(attrs)
    }

    // Video codec configuration
    var codecConfig = TLV8.Builder()
    codecConfig.add(0x01, byte: 0x00)  // CodecType: H.264
    codecConfig.add(0x02, tlv: codecParams)  // Single CodecParameters with lists
    codecConfig.addList(0x03, tlvs: resTLVs)  // Attributes with delimiters

    var config = TLV8.Builder()
    config.add(0x01, tlv: codecConfig)  // VIDEO_CODEC_CONFIGURATION
    return config
  }

  /// SupportedAudioRecordingConfiguration
  /// Recording codec types differ from streaming: AAC-LC = 0, AAC-ELD = 1.
  /// Encoding matches hap-nodejs: sample rates delimited, codec configs delimited.
  func supportedAudioRecordingConfig() -> TLV8.Builder {
    // AAC-ELD codec -- preferred by Apple HKSV hubs
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
  func handleSelectedRecordingConfig(_ data: Data) {
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]
    for (tag, val) in tlvs {
      if tag == 0x01 {
        // Selected general recording configuration
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        for (stag, _) in sub {
          logger.debug("Selected recording config tag 0x\(String(stag, radix: 16))")
        }
      } else if tag == 0x02 {
        // Selected video configuration
        logger.debug("Selected video recording config: \(val.count) bytes")
      } else if tag == 0x03 {
        // Selected audio configuration
        logger.debug("Selected audio recording config: \(val.count) bytes")
      }
    }
  }
}
