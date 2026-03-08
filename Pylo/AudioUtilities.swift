import AVFoundation
import Accelerate
import AudioToolbox
import Foundation

// MARK: - Shared Audio Conversion

/// Convert PCM audio data to Float32 at 16kHz mono.
/// Uses vDSP for vectorized int16→float conversion, channel downmixing,
/// and linear-interpolation resampling.
///
/// Several vDSP calls here read from and write to the same array (in-place).
/// Swift's exclusivity rules forbid passing `&array` for both the input and
/// output parameters of a function, even though vDSP supports aliased
/// source/destination pointers. We use `withUnsafeMutableBufferPointer` to
/// obtain a single pointer and pass it for both roles, which is safe because
/// vDSP guarantees correct in-place operation and the closure holds exclusive
/// access to the buffer for its duration.
nonisolated func convertToFloat32At16kHz(
  _ data: Data, sourceASBD: AudioStreamBasicDescription
) -> Data {
  let sourceSampleRate = sourceASBD.mSampleRate
  let sourceChannels = Int(sourceASBD.mChannelsPerFrame)
  let isFloat = (sourceASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0
  let is16Bit = sourceASBD.mBitsPerChannel == 16

  guard sourceASBD.mBytesPerFrame > 0, sourceChannels > 0 else { return Data() }

  let totalFrames = data.count / Int(sourceASBD.mBytesPerFrame)
  var monoFloat: [Float]

  if isFloat && sourceASBD.mBitsPerChannel == 32 {
    if sourceChannels == 1 {
      monoFloat = data.withUnsafeBytes { Array($0.assumingMemoryBound(to: Float.self)) }
    } else {
      monoFloat = [Float](repeating: 0, count: totalFrames)
      monoFloat.withUnsafeMutableBufferPointer { dst in
        data.withUnsafeBytes { ptr in
          let src = ptr.assumingMemoryBound(to: Float.self).baseAddress!
          var scale = 1.0 / Float(sourceChannels)
          for ch in 0..<sourceChannels {
            vDSP_vsma(
              src + ch, vDSP_Stride(sourceChannels),
              &scale, dst.baseAddress!, 1, dst.baseAddress!, 1,
              vDSP_Length(totalFrames))
          }
        }
      }
    }
  } else if is16Bit {
    let int16Count = data.count / 2
    // Vectorized Int16 → Float conversion
    var allFloat = [Float](unsafeUninitializedCapacity: int16Count) { buf, count in
      data.withUnsafeBytes { ptr in
        vDSP_vflt16(
          ptr.assumingMemoryBound(to: Int16.self).baseAddress!, 1,
          buf.baseAddress!, 1, vDSP_Length(int16Count))
      }
      count = int16Count
    }
    var divisor: Float = 32768.0
    allFloat.withUnsafeMutableBufferPointer { buf in
      vDSP_vsdiv(buf.baseAddress!, 1, &divisor, buf.baseAddress!, 1, vDSP_Length(int16Count))
    }

    if sourceChannels == 1 {
      monoFloat = allFloat
    } else {
      monoFloat = [Float](repeating: 0, count: totalFrames)
      var scale = 1.0 / Float(sourceChannels)
      monoFloat.withUnsafeMutableBufferPointer { dst in
        allFloat.withUnsafeBufferPointer { src in
          for ch in 0..<sourceChannels {
            vDSP_vsma(
              src.baseAddress! + ch, vDSP_Stride(sourceChannels),
              &scale, dst.baseAddress!, 1, dst.baseAddress!, 1,
              vDSP_Length(totalFrames))
          }
        }
      }
    }
  } else {
    return Data()
  }

  // Resample to 16kHz using vectorized linear interpolation
  if abs(sourceSampleRate - 16000) > 1 {
    let ratio = 16000.0 / sourceSampleRate
    let outputCount = Int((Double(monoFloat.count) * ratio).rounded())
    guard outputCount > 0 else { return Data() }

    // Build ramp of fractional source indices for vDSP_vlint
    var control = [Float](unsafeUninitializedCapacity: outputCount) { buf, count in
      var start: Float = 0
      var step = Float(1.0 / ratio)
      vDSP_vramp(&start, &step, buf.baseAddress!, 1, vDSP_Length(outputCount))
      // Clamp to valid range so vlint doesn't read out of bounds.
      // vDSP_vlint reads both floor(B[n]) and floor(B[n])+1 for interpolation,
      // so the maximum control value must be count-2 (not count-1).
      var lo: Float = 0
      var hi = Float(max(monoFloat.count - 2, 0))
      vDSP_vclip(buf.baseAddress!, 1, &lo, &hi, buf.baseAddress!, 1, vDSP_Length(outputCount))
      count = outputCount
    }
    var resampled = [Float](repeating: 0, count: outputCount)
    vDSP_vlint(
      &monoFloat, &control, 1, &resampled, 1,
      vDSP_Length(outputCount), vDSP_Length(monoFloat.count))
    monoFloat = resampled
  }

  return monoFloat.withUnsafeBytes { Data($0) }
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

// MARK: - Video Orientation

/// Map a rotation angle (0/90/180/270) to the legacy AVCaptureVideoOrientation
/// used on iOS <17 where `videoRotationAngle` is unavailable.
nonisolated func videoOrientation(from angle: Int) -> AVCaptureVideoOrientation {
  switch angle {
  case 0: return .landscapeRight
  case 180: return .landscapeLeft
  case 270: return .portraitUpsideDown
  default: return .portrait  // 90° or fallback
  }
}

// MARK: - Audio Converter Callback Data

/// Helper for passing PCM data through the AudioConverter encoder C callback.
struct AudioEncoderInput {
  var srcData: UnsafeRawPointer?
  var srcSize: UInt32
  var consumed: Bool
}
