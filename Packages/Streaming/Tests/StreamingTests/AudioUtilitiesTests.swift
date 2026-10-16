import AVFoundation
import FragmentedMP4
import Locked
import Testing

@testable import Streaming

@Suite struct AudioUtilitiesTests {

  @Test("4K capture handoff preserves recording audio", arguments: [false, true])
  func monitoringAudioHandoff(recordIn4K: Bool) {
    let monitoring = MonitoringCaptureSession()
    monitoring.recordIn4K = recordIn4K
    let writer = FragmentedMP4Writer()
    writer.includeAudioTrack = true
    monitoring.fragmentWriter = writer
    let capture = AVCaptureSession()
    monitoring.mState.withLockUnchecked { $0.captureSession = capture }
    #expect(monitoring.handoff() === capture)
    #expect(monitoring.mState.valueUnchecked.captureSession == nil)
    #expect(writer.includeAudioTrack == recordIn4K)
  }

  @Test("Recording reuses encoded microphone frames and disarming preserves live audio")
  func recordingAudioHandoff() throws {
    let session = CameraStreamSession(
      sessionID: Data(repeating: 0, count: 16),
      controllerAddress: "127.0.0.1", controllerVideoPort: 5000, controllerAudioPort: 5001,
      videoSRTPKey: Data(repeating: 0, count: 16), videoSRTPSalt: Data(repeating: 0, count: 14),
      audioSRTPKey: Data(repeating: 0, count: 16), audioSRTPSalt: Data(repeating: 0, count: 14),
      localAddress: "127.0.0.1", localVideoPort: 6000, localAudioPort: 6001,
      videoSSRC: 1, audioSSRC: 2)
    let frames = Locked<[Data]>(initialState: [])
    session.onRecordingAudioFrame = { frame in frames.withLock { $0.append(frame) } }
    let samples = (0..<480).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.2 }
    let pcm = samples.withUnsafeBytes { Data($0) }
    try session.audioQueue.sync {
      session.setupAudioEncoder()
      let converter = try #require(session.audioConverter)
      var bitrate: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      #expect(
        AudioConverterGetProperty(converter, kAudioConverterEncodeBitRate, &size, &bitrate) == noErr
      )
      #expect(bitrate == 16000)
      for _ in 0..<6 { session.encodeAndSendAudioFrame(pcm) }
    }
    session.rtpQueue.sync {}
    let recordedCount = frames.value.count
    #expect(recordedCount > 0)
    #expect(frames.value.allSatisfy { !$0.isEmpty })
    let sentCount = session.audioRTPStats.value.packetsSent
    #expect(Int(sentCount) == recordedCount)
    session.stopRecording()
    session.audioQueue.sync {
      for _ in 0..<6 { session.encodeAndSendAudioFrame(pcm) }
    }
    session.rtpQueue.sync {}
    #expect(frames.value.count == recordedCount)
    #expect(session.audioRTPStats.value.packetsSent > sentCount)
    session.stopStreaming()
  }

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

  @Test func float32StereoAt16kHzDownmixes() {
    // Stereo Float32 at 16kHz — should downmix to mono.
    // L=1.0, R=-1.0 → average = 0.0 per frame
    let samples: [Float] = [1.0, -1.0, 0.6, 0.2]
    let data = samples.withUnsafeBytes { Data($0) }

    let asbd = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: 8,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    let output = result.withUnsafeBytes { Array($0.assumingMemoryBound(to: Float.self)) }

    #expect(output.count == 2)
    #expect(abs(output[0]) < 0.01)  // (1.0 + -1.0) / 2 = 0.0
    #expect(abs(output[1] - 0.4) < 0.01)  // (0.6 + 0.2) / 2 = 0.4
  }

  @Test func resamplingAt44100Hz() {
    // 44.1kHz mono Float32 → 16kHz (non-integer ratio ≈ 0.3628).
    let count = 441  // 10ms at 44.1kHz
    let samples = [Float](repeating: 0.25, count: count)
    let data = samples.withUnsafeBytes { Data($0) }

    let asbd = AudioStreamBasicDescription(
      mSampleRate: 44100,
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

    // 441 * (16000/44100) ≈ 159.86 → 160
    #expect(output.count == 160)
    // Constant input → output should be constant (interpolation of equal values)
    for sample in output {
      #expect(abs(sample - 0.25) < 0.01)
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
