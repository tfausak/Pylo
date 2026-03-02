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
      pcmFloat32 = Self.convertToFloat32At16kHz(rawData, sourceASBD: asbd)
    } else {
      logger.warning("Audio: unexpected format ID \(asbd?.mFormatID ?? 0)")
      return
    }

    // Accumulate PCM and encode when we have enough for an AAC-ELD frame
    withState { $0.pcmAccumulator.append(pcmFloat32) }
    let frameSizeBytes = aacFrameSamples * 4  // 480 samples * 4 bytes/sample (Float32)

    while true {
      let frameData: Data? = withState {
        guard $0.pcmAccumulator.count >= frameSizeBytes else { return nil }
        let frame = Data($0.pcmAccumulator.prefix(frameSizeBytes))
        $0.pcmAccumulator = Data($0.pcmAccumulator.dropFirst(frameSizeBytes))
        return frame
      }
      guard let frameData else { break }
      encodeAndAppendAudioFrame(frameData)
    }
  }

  private nonisolated func encodeAndAppendAudioFrame(_ pcmData: Data) {
    let converter = withState { $0.audioConverter }
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
  private nonisolated static func convertToFloat32At16kHz(
    _ data: Data, sourceASBD: AudioStreamBasicDescription
  ) -> Data {
    let sourceSampleRate = sourceASBD.mSampleRate
    let sourceChannels = Int(sourceASBD.mChannelsPerFrame)
    let isFloat = (sourceASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let is16Bit = sourceASBD.mBitsPerChannel == 16

    guard sourceASBD.mBytesPerFrame > 0, sourceChannels > 0 else { return Data() }

    // Pre-allocate to avoid repeated heap growth during the per-callback conversion
    let totalSamples = data.count / Int(sourceASBD.mBytesPerFrame)
    let monoSamples = totalSamples / sourceChannels
    var floatSamples: [Float] = []
    floatSamples.reserveCapacity(monoSamples)

    if isFloat && sourceASBD.mBitsPerChannel == 32 {
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

// MARK: - Audio Converter Callback Data

/// Helper for passing PCM data through the AudioConverter encoder C callback.
private struct AudioEncoderInput {
  var srcData: UnsafeRawPointer?
  var srcSize: UInt32
  var consumed: Bool
}
