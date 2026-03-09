import AVFAudio
import MediaPlayer
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
    var savedVolume: Float?
    var sampleTime: Float = 0
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

      // Configure audio session for playback
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)
      } catch {
        logger.error("Failed to configure audio session: \(error)")
      }

      // Save current volume and set to max
      let currentVolume = AVAudioSession.sharedInstance().outputVolume
      _state.withLock { $0.savedVolume = currentVolume }
      DispatchQueue.main.async { Self.setSystemVolume(1.0) }

      let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
      let sourceNode = AVAudioSourceNode(format: format) {
        [weak self] _, _, frameCount, bufferList in
        guard let self else { return noErr }
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        let sampleTime = self._state.withLock { state -> Float in
          let t = state.sampleTime
          state.sampleTime = t + Float(frameCount)
          return t
        }

        let freqLow = Self.frequencyLow
        let freqHigh = Self.frequencyHigh
        let oscRate = Self.oscillationRate

        for frame in 0..<Int(frameCount) {
          let t = (sampleTime + Float(frame)) / sampleRate
          // Oscillate between low and high frequency using a smooth sine envelope
          let blend = (sin(2.0 * .pi * oscRate * t) + 1.0) / 2.0
          let frequency = freqLow + (freqHigh - freqLow) * blend
          let phase = 2.0 * .pi * frequency * t
          let sample = sin(phase) * 0.8  // 80% amplitude to avoid clipping

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
        return
      }

      _state.withLock {
        $0.engine = engine
        $0.isPlaying = true
        $0.sampleTime = 0
      }
      logger.info("Siren started")
      onActiveChange?(true)
    }
  }

  func stop() {
    audioQueue.async { [self] in
      guard _state.withLock({ $0.isPlaying }) else { return }

      let (engine, savedVolume) = _state.withLock { state -> (AVAudioEngine?, Float?) in
        let e = state.engine
        let v = state.savedVolume
        state.engine = nil
        state.isPlaying = false
        state.sampleTime = 0
        state.savedVolume = nil
        return (e, v)
      }

      engine?.stop()

      // Restore previous volume
      if let savedVolume {
        DispatchQueue.main.async { Self.setSystemVolume(savedVolume) }
      }

      logger.info("Siren stopped")
      onActiveChange?(false)
    }
  }

  // MARK: - Volume Control

  /// Set system volume using MPVolumeView's hidden slider.
  @MainActor
  private static func setSystemVolume(_ volume: Float) {
    let volumeView = MPVolumeView()
    if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
      slider.value = volume
    }
  }
}
