import AVFAudio
import Locked
import os

/// Generates a two-tone alarm siren via AVAudioEngine.
/// Oscillates between two frequencies to produce a classic home security alarm pattern.
nonisolated final class SirenPlayer: @unchecked Sendable {

  var onActiveChange: ((Bool) -> Void)? {
    get { _onActiveChange.value }
    set { _onActiveChange.value = newValue }
  }

  var isPlaying: Bool { _state.withLockUnchecked { $0.isPlaying } }

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
    var sourceNode: AVAudioSourceNode?
    var phases: UnsafeMutablePointer<Float>?
  }

  private let _state = Locked(initialState: State())

  init() {
    #if os(iOS)
      NotificationCenter.default.addObserver(
        self, selector: #selector(handleInterruption(_:)),
        name: AVAudioSession.interruptionNotification, object: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(handleEngineConfigChange(_:)),
        name: .AVAudioEngineConfigurationChange, object: nil)
    #endif
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    // Synchronous cleanup — don't dispatch async work that captures self.
    let (engine, sourceNode, phases) = _state.withLockUnchecked {
      state -> (AVAudioEngine?, AVAudioSourceNode?, UnsafeMutablePointer<Float>?) in
      let e = state.engine
      let s = state.sourceNode
      let p = state.phases
      state.engine = nil
      state.sourceNode = nil
      state.phases = nil
      state.isPlaying = false
      return (e, s, p)
    }
    if let sourceNode { engine?.detach(sourceNode) }
    engine?.stop()
    phases?.deallocate()
  }

  func start() {
    audioQueue.async { [self] in
      guard !_state.withLockUnchecked({ $0.isPlaying }) else { return }

      // Configure audio session BEFORE creating the engine so the output
      // node's format reflects the session settings (correct sample rate).
      #if os(iOS)
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(
            .playAndRecord, mode: .default,
            options: [.defaultToSpeaker, .mixWithOthers])
          try session.setActive(true)
        } catch {
          logger.error("Failed to configure audio session: \(error)")
          onActiveChange?(false)
          return
        }
      #endif

      let engine = AVAudioEngine()
      let sampleRate = Float(engine.outputNode.outputFormat(forBus: 0).sampleRate)
      guard sampleRate > 0 else {
        logger.error("Audio output not available (sample rate is 0)")
        Self.deactivateAudioSession()
        onActiveChange?(false)
        return
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
        Self.deactivateAudioSession()
        onActiveChange?(false)
        return
      }

      _state.withLockUnchecked {
        $0.engine = engine
        $0.sourceNode = sourceNode
        $0.phases = phases
        $0.isPlaying = true
      }
      logger.info("Siren started")
      onActiveChange?(true)
    }
  }

  func stop() {
    audioQueue.async { [self] in
      tearDown()
    }
  }

  /// Tears down the audio engine and notifies that the siren stopped.
  /// Must be called on `audioQueue`. The `onActiveChange` callback fires on
  /// `audioQueue`, which is safe because the downstream path
  /// (HAPSirenAccessory.updateOn → notifySubscribers) dispatches to the
  /// server's own queue internally.
  private func tearDown() {
    guard _state.withLockUnchecked({ $0.isPlaying }) else { return }

    let (engine, sourceNode, phases) = _state.withLockUnchecked {
      state -> (AVAudioEngine?, AVAudioSourceNode?, UnsafeMutablePointer<Float>?) in
      let e = state.engine
      let s = state.sourceNode
      let p = state.phases
      state.engine = nil
      state.sourceNode = nil
      state.phases = nil
      state.isPlaying = false
      return (e, s, p)
    }

    // Detach the source node first to ensure the render callback is no
    // longer invoked before we deallocate the phase accumulators.
    if let sourceNode { engine?.detach(sourceNode) }
    engine?.stop()
    phases?.deallocate()
    Self.deactivateAudioSession()

    logger.info("Siren stopped")
    onActiveChange?(false)
  }

  #if os(iOS)
    private static func deactivateAudioSession() {
      try? AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    }
  #else
    private static func deactivateAudioSession() {}
  #endif

  // MARK: - Audio Session Interruption

  #if os(iOS)
    @objc private func handleInterruption(_ notification: Notification) {
      guard let info = notification.userInfo,
        let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }

      switch type {
      case .began:
        logger.info("Audio session interrupted — stopping siren")
        audioQueue.async { [self] in tearDown() }

      case .ended:
        // Don't auto-restart — the HAP state was already reset to off.
        // The user must re-trigger the siren from HomeKit.
        break

      @unknown default:
        break
      }
    }

    @objc private func handleEngineConfigChange(_ notification: Notification) {
      // The engine's audio hardware config changed (e.g. route change, sample
      // rate change). The engine is stopped and must be restarted, but the
      // node graph remains intact. Try to restart; if that fails, tear down.
      audioQueue.async { [self] in
        guard _state.withLockUnchecked({ $0.isPlaying }) else { return }
        guard let engine = _state.withLockUnchecked({ $0.engine }) else { return }

        do {
          try engine.start()
          logger.debug("Audio engine restarted after config change")
        } catch {
          logger.error("Failed to restart audio engine after config change: \(error)")
          tearDown()
        }
      }
    }
  #endif
}
