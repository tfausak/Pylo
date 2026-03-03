import AudioToolbox
@preconcurrency import CoreMedia
import Foundation
import FragmentedMP4
import os

// MARK: - Audio Encoding

extension MonitoringCaptureSession {

  nonisolated func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    let converter = withState { $0.audioConverter }
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
      pcmFloat32 = convertToFloat32At16kHz(rawData, sourceASBD: asbd)
    } else {
      logger.warning("Audio: unexpected format ID \(asbd?.mFormatID ?? 0)")
      return
    }

    // Accumulate PCM and encode when we have enough for an AAC-ELD frame
    withState { $0.pcmAccumulator.append(pcmFloat32) }
    let frameSizeBytes = aacFrameSamples * 4  // 480 samples * 4 bytes/sample (Float32)

    // Extract all complete frames under a single lock acquisition, then encode outside.
    let frames: [Data] = withState { state in
      var result: [Data] = []
      var offset = state.pcmAccumulator.startIndex
      while offset + frameSizeBytes <= state.pcmAccumulator.endIndex {
        result.append(Data(state.pcmAccumulator[offset..<offset + frameSizeBytes]))
        offset += frameSizeBytes
      }
      if offset > state.pcmAccumulator.startIndex {
        state.pcmAccumulator.removeFirst(offset - state.pcmAccumulator.startIndex)
      }
      return result
    }
    for frameData in frames {
      encodeAndAppendAudioFrame(frameData)
    }
  }

  private nonisolated func encodeAndAppendAudioFrame(_ pcmData: Data) {
    let converter = withState { $0.audioConverter }
    guard let converter else { return }

    let outputBufferSize = 1024
    let aacData: Data? = withUnsafeTemporaryAllocation(
      byteCount: outputBufferSize, alignment: 1
    ) { outputBuf -> Data? in
      var packetSize: UInt32 = 1

      var outputBufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 1,
          mDataByteSize: UInt32(outputBufferSize),
          mData: outputBuf.baseAddress
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
        return nil
      }

      let encodedSize = Int(outputBufferList.mBuffers.mDataByteSize)
      guard encodedSize > 0 else { return nil }  // priming frame
      return Data(bytes: outputBuf.baseAddress!, count: encodedSize)
    }

    guard let aacData else { return }
    // Append raw AAC-ELD frame to fMP4 writer (no AU header — fMP4 uses raw frames)
    fragmentWriter?.appendAudioSample(aacData)
  }


  /// Create an AAC-ELD encoder (PCM Float32 16kHz mono → AAC-ELD 24kbps).
  nonisolated static func createAudioEncoder(logger: Logger) -> AudioConverterRef? {
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
}

