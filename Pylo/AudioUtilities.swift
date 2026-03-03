import AudioToolbox
import Foundation

// MARK: - Shared Audio Conversion

/// Convert PCM audio data to Float32 at 16kHz mono.
nonisolated func convertToFloat32At16kHz(
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
    // AudioToolbox wrote this buffer as Float32 samples; use assumingMemoryBound
    // rather than bindMemory to avoid rebinding memory that Data still references
    // as UInt8 (which is technically undefined behavior per Swift's aliasing rules).
    data.withUnsafeBytes { ptr in
      let floatPtr = ptr.assumingMemoryBound(to: Float.self)
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
      let int16Ptr = ptr.assumingMemoryBound(to: Int16.self)
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

  // Resample to 16kHz if needed. Allocates a temporary [Float] per call;
  // acceptable because audio buffers are small (~480 samples) and this runs
  // at audio callback rate (~30-50Hz), not video frame rate.
  if abs(sourceSampleRate - 16000) > 1 {
    let ratio = 16000.0 / sourceSampleRate
    let outputCount = Int((Double(floatSamples.count) * ratio).rounded())
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

// MARK: - AAC-ELD Encoder Factory

/// Create an AAC-ELD encoder (PCM Float32 16kHz mono → AAC-ELD 24kbps).
/// Used by both CameraStreamSession and MonitoringCaptureSession.
nonisolated func createAACELDEncoder() -> AudioConverterRef? {
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
  guard status == noErr, let converter else { return nil }

  var bitrate: UInt32 = 24000
  AudioConverterSetProperty(
    converter, kAudioConverterEncodeBitRate,
    UInt32(MemoryLayout<UInt32>.size), &bitrate)

  return converter
}

// MARK: - Audio Converter Callback Data

/// Helper for passing PCM data through the AudioConverter encoder C callback.
struct AudioEncoderInput {
  var srcData: UnsafeRawPointer?
  var srcSize: UInt32
  var consumed: Bool
}
