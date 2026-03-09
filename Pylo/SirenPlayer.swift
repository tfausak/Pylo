import AVFAudio
import os

/// Generates a two-tone alarm siren via AVAudioEngine.
/// Oscillates between two frequencies to produce a classic home security alarm pattern.
nonisolated final class SirenPlayer: @unchecked Sendable {

  var onActiveChange: ((Bool) -> Void)? {
    get { _onActiveChange.withLock { $0 } }
    set { _onActiveChange.withLock { $0 = newValue } }
  }

  var isPlaying: Bool { _state.withLock { $0.isPlaying } }

  private let _onActiveChange = Locked<((Bool) -> Void)?>(initialState: nil)
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SirenPlayer")
  private let audioQueue = DispatchQueue(
    label: "\(Bundle.main.bundleIdentifier!).siren-player", qos: .userInitiated)

  // Siren tone parameters
  private static let frequencyLow: Float = 800
  private static let frequencyHigh: Float = 1200
  private static let oscillationRate: Float = 2.0  // full cycles per second

  private struct State {
    var isPlaying = false
    var engine: AVAudioEngine?
    var phases: UnsafeMutablePointer<Float>?
  }

  private let _state = Locked(initialState: State())

  init() {}

  func start() {
    audioQueue.async { [self] in
      guard !_state.withLock({ $0.isPlaying }) else { return }

      let engine = AVAudioEngine()
      let sampleRate = Float(engine.outputNode.outputFormat(forBus: 0).sampleRate)
      guard sampleRate > 0 else {
        logger.error("Audio output not available (sample rate is 0)")
        return
      }

      // Configure audio session for playback. Use .playAndRecord with
      // .mixWithOthers to coexist with the camera's AVCaptureSession audio.
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
          .playAndRecord, mode: .default,
          options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)
      } catch {
        logger.error("Failed to configure audio session: \(error)")
      }

      let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!

      // Two phase accumulators accessed exclusively on the audio render
      // thread — no lock needed since render callbacks are serialized.
      // [0] = tone phase, [1] = oscillation (sweep) phase
      let phases = UnsafeMutablePointer<Float>.allocate(capacity: 2)
      phases.initialize(repeating: 0, count: 2)

      let freqLow = Self.frequencyLow
      let freqHigh = Self.frequencyHigh
      let oscRate = Self.oscillationRate
      let twoPi: Float = 2.0 * .pi

      let sourceNode = AVAudioSourceNode(format: format) {
        _, _, frameCount, bufferList in
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)

        for frame in 0..<Int(frameCount) {
          // Advance oscillation phase to get smooth frequency sweep
          phases[1] += twoPi * oscRate / sampleRate
          if phases[1] > twoPi { phases[1] -= twoPi }
          let blend = (sin(phases[1]) + 1.0) / 2.0
          let frequency = freqLow + (freqHigh - freqLow) * blend

          // Accumulate tone phase to avoid discontinuities from varying frequency
          phases[0] += twoPi * frequency / sampleRate
          if phases[0] > twoPi { phases[0] -= twoPi }

          let sample = sin(phases[0]) * 0.8  // 80% amplitude to avoid clipping

          for buffer in ablPointer {
            let ptr = buffer.mData?.assumingMemoryBound(to: Float.self)
            ptr?[frame] = sample
          }
        }
        return noErr
      }

      engine.attach(sourceNode)
      engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
      engine.mainMixerNode.outputVolume = 1.0

      do {
        try engine.start()
      } catch {
        logger.error("Failed to start audio engine: \(error)")
        phases.deallocate()
        return
      }

      _state.withLock {
        $0.engine = engine
        $0.phases = phases
        $0.isPlaying = true
      }
      logger.info("Siren started")
      onActiveChange?(true)
    }
  }

  func stop() {
    audioQueue.async { [self] in
      guard _state.withLock({ $0.isPlaying }) else { return }

      let (engine, phases) = _state.withLock {
        state -> (AVAudioEngine?, UnsafeMutablePointer<Float>?) in
        let e = state.engine
        let p = state.phases
        state.engine = nil
        state.phases = nil
        state.isPlaying = false
        return (e, p)
      }

      engine?.stop()
      phases?.deallocate()

      logger.info("Siren stopped")
      onActiveChange?(false)
    }
  }
}
