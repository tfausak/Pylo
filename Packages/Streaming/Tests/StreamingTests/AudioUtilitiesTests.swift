import AVFoundation
import Testing

@testable import Streaming

@Suite struct AudioUtilitiesTests {

  // MARK: - convertToFloat32At16kHz

  @Test func float32MonoAt16kHzPassesThrough() {
    // Input is already Float32/16kHz/mono — should pass through unchanged.
    let samples: [Float] = [0.0, 0.5, -0.5, 1.0]
    let data = samples.withUnsafeBytes { Data($0) }

    let asbd = AudioStreamBasicDescription(
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

    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    let output = result.withUnsafeBytes { Array($0.assumingMemoryBound(to: Float.self)) }

    #expect(output.count == 4)
    for (a, b) in zip(samples, output) {
      #expect(abs(a - b) < 0.001)
    }
  }

  @Test func int16MonoAt16kHzConverts() {
    // Int16 samples at 16kHz mono — should convert to Float32 in [-1, 1].
    let samples: [Int16] = [0, 16384, -16384, 32767]
    let data = samples.withUnsafeBytes { Data($0) }

    let asbd = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0
    )

    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    let output = result.withUnsafeBytes { Array($0.assumingMemoryBound(to: Float.self)) }

    #expect(output.count == 4)
    #expect(abs(output[0]) < 0.001)  // 0
    #expect(abs(output[1] - 0.5) < 0.001)  // 16384/32768
    #expect(abs(output[2] + 0.5) < 0.001)  // -16384/32768
    #expect(output[3] > 0.99)  // 32767/32768 ≈ 1.0
  }

  @Test func int16StereoAt16kHzDownmixes() {
    // Stereo Int16 at 16kHz — should downmix to mono.
    // L=16384, R=-16384 → average should be ~0
    let samples: [Int16] = [16384, -16384, 16384, -16384]
    let data = samples.withUnsafeBytes { Data($0) }

    let asbd = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 16,
      mReserved: 0
    )

    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    let output = result.withUnsafeBytes { Array($0.assumingMemoryBound(to: Float.self)) }

    // 2 frames of stereo → 2 mono samples
    #expect(output.count == 2)
    for sample in output {
      #expect(abs(sample) < 0.01)  // L+R cancel out
    }
  }

  @Test func resamplingChangesCount() {
    // 48kHz mono Float32 → 16kHz should produce ~1/3 the samples.
    let count = 480  // 10ms at 48kHz
    let samples = [Float](repeating: 0.5, count: count)
    let data = samples.withUnsafeBytes { Data($0) }

    let asbd = AudioStreamBasicDescription(
      mSampleRate: 48000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    let output = result.withUnsafeBytes { Array($0.assumingMemoryBound(to: Float.self)) }

    // 480 * (16000/48000) = 160
    #expect(output.count == 160)
    // All values should be approximately 0.5 (constant input)
    for sample in output {
      #expect(abs(sample - 0.5) < 0.01)
    }
  }

  @Test func singleSampleDoesNotCrash() {
    // Edge case: single sample at non-16kHz should not crash (vDSP_vlint needs >= 2).
    let samples: [Float] = [0.5]
    let data = samples.withUnsafeBytes { Data($0) }

    let asbd = AudioStreamBasicDescription(
      mSampleRate: 48000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    // Should return the single sample without resampling (skip due to < 2 samples)
    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    let output = result.withUnsafeBytes { Array($0.assumingMemoryBound(to: Float.self)) }
    #expect(output.count == 1)
    #expect(abs(output[0] - 0.5) < 0.001)
  }

  @Test func emptyInputReturnsEmpty() {
    let asbd = AudioStreamBasicDescription(
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
    let result = convertToFloat32At16kHz(Data(), sourceASBD: asbd)
    #expect(result.isEmpty)
  }

  @Test func unsupportedFormatReturnsEmpty() {
    // 8-bit audio is neither Float32 nor Int16
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 1,
      mFramesPerPacket: 1,
      mBytesPerFrame: 1,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 8,
      mReserved: 0
    )
    let result = convertToFloat32At16kHz(Data([0x7F]), sourceASBD: asbd)
    #expect(result.isEmpty)
  }

  // MARK: - videoOrientation

  @Test func videoOrientationMapping() {
    #expect(videoOrientation(from: 0) == .landscapeRight)
    #expect(videoOrientation(from: 90) == .portrait)
    #expect(videoOrientation(from: 180) == .landscapeLeft)
    #expect(videoOrientation(from: 270) == .portraitUpsideDown)
  }

  @Test func videoOrientationDefaultsToPortrait() {
    #expect(videoOrientation(from: 45) == .portrait)
    #expect(videoOrientation(from: -1) == .portrait)
    #expect(videoOrientation(from: 360) == .portrait)
  }
}
