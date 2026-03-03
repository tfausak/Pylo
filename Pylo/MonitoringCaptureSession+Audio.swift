import AudioToolbox
@preconcurrency import CoreMedia
import Foundation
import FragmentedMP4
import os

// MARK: - Audio Encoding

extension MonitoringCaptureSession {

  nonisolated func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard let converter = mState.withLockUnchecked({ $0.audioConverter }) else { return }

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(
      blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard let ptr = dataPointer, totalLength > 0 else { return }

    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee

    // Zero-copy wrapper around the CMBlockBuffer memory. The pointer is valid
    // for this callback's duration and convertToFloat32At16kHz reads synchronously.
    let rawData = Data(
      bytesNoCopy: UnsafeMutableRawPointer(ptr), count: totalLength, deallocator: .none)

    let pcmFloat32: Data
    if let asbd, asbd.mFormatID == kAudioFormatLinearPCM {
      pcmFloat32 = convertToFloat32At16kHz(rawData, sourceASBD: asbd)
    } else {
      logger.warning("Audio: unexpected format ID \(asbd?.mFormatID ?? 0)")
      return
    }

    // Accumulate PCM and extract complete AAC-ELD frames under a single lock.
    // Extract a single contiguous block rather than per-frame Data copies, then
    // iterate via pointer math to avoid per-frame heap allocations.
    let frameSizeBytes = aacFrameSamples * 4  // 480 samples * 4 bytes/sample (Float32)
    let encodableData: Data = mState.withLock { state in
      state.pcmAccumulator.append(pcmFloat32)
      let frameCount = state.pcmAccumulator.count / frameSizeBytes
      let consumeBytes = frameCount * frameSizeBytes
      guard consumeBytes > 0 else { return Data() }
      if state.pcmAccumulator.count == consumeBytes {
        // All data consumed — swap avoids copying
        var result = Data()
        swap(&result, &state.pcmAccumulator)
        return result
      }
      let result = Data(state.pcmAccumulator.prefix(consumeBytes))
      state.pcmAccumulator.removeFirst(consumeBytes)
      return result
    }
    guard !encodableData.isEmpty else { return }
    encodableData.withUnsafeBytes { buf in
      var offset = 0
      while offset + frameSizeBytes <= buf.count {
        let framePtr = UnsafeRawBufferPointer(rebasing: buf[offset..<offset + frameSizeBytes])
        encodeAndAppendAudioFrame(framePtr, converter: converter)
        offset += frameSizeBytes
      }
    }
  }

  private nonisolated func encodeAndAppendAudioFrame(
    _ pcmBuffer: UnsafeRawBufferPointer, converter: AudioConverterRef
  ) {
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

      guard let pcmBase = pcmBuffer.baseAddress else { return nil }

      var cbData = AudioEncoderInput(
        srcData: pcmBase,
        srcSize: UInt32(pcmBuffer.count),
        consumed: false
      )

      let status: OSStatus = withUnsafeMutablePointer(to: &cbData) { cbPtr in
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

}
