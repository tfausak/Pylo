import AVFAudio
import SoundAnalysis
import os

/// Classifies ambient sound using Apple's built-in sound classifier to detect
/// smoke alarm sounds. Uses AVAudioEngine for microphone input, independent
/// from the camera's AVCaptureSession audio pipeline.
///
/// All mutable instance state (engine, analyzer, cooldownItem) is accessed
/// exclusively on `analysisQueue`. The SNResultsObserving callbacks are
/// re-dispatched to `analysisQueue` to maintain this invariant.
nonisolated final class SoundClassifier: NSObject, SNResultsObserving, @unchecked Sendable {

  var onSmokeDetected: ((Bool) -> Void)? {
    get { _onSmokeDetected.withLock { $0 } }
    set { _onSmokeDetected.withLock { $0 = newValue } }
  }

  /// Confidence threshold for triggering detection (0.0–1.0).
  var confidenceThreshold: Double {
    get { _state.withLock { $0.confidenceThreshold } }
    set { _state.withLock { $0.confidenceThreshold = newValue } }
  }

  /// Seconds after last detection before clearing the detected state.
  var cooldown: TimeInterval {
    get { _state.withLock { $0.cooldown } }
    set { _state.withLock { $0.cooldown = newValue } }
  }

  private let _onSmokeDetected = Locked<((Bool) -> Void)?>(initialState: nil)

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier!, category: "SoundClassifier")

  /// Sound classification identifiers that indicate a smoke alarm.
  /// These are identifiers from Apple's built-in sound classifier (version 1).
  private static let smokeIdentifiers: Set<String> = [
    "smoke_detector_smoke_alarm",
    "fire_alarm_fire_detector_smoke_detector",
  ]

  private struct State {
    var isRunning = false
    var isDetected = false
    var lastDetectionTime: Date?
    var confidenceThreshold: Double = 0.5
    var cooldown: TimeInterval = 30
  }

  private let _state = Locked(initialState: State())

  /// Serial queue that owns all mutable instance state (engine, analyzer,
  /// cooldownItem). SNResultsObserving callbacks are re-dispatched here.
  private let analysisQueue = DispatchQueue(
    label: "\(Bundle.main.bundleIdentifier!).sound-classifier", qos: .utility)

  // All accessed exclusively on analysisQueue
  private var engine: AVAudioEngine?
  private var analyzer: SNAudioStreamAnalyzer?
  private var request: SNClassifySoundRequest?
  private var cooldownItem: DispatchWorkItem?

  override init() {
    super.init()
  }

  func start() {
    analysisQueue.async { [self] in
      guard !_state.withLock({ $0.isRunning }) else { return }

      // Configure audio session so the microphone is available even when
      // the camera isn't active. Use .mixWithOthers to coexist with the
      // camera's AVCaptureSession audio pipeline.
      #if os(iOS)
        do {
          let audioSession = AVAudioSession.sharedInstance()
          try audioSession.setCategory(
            .playAndRecord, mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
          try audioSession.setActive(true)
        } catch {
          logger.error("AVAudioSession setup error: \(error)")
          return
        }
      #endif

      let audioEngine = AVAudioEngine()
      let inputNode = audioEngine.inputNode
      let inputFormat = inputNode.outputFormat(forBus: 0)

      guard inputFormat.sampleRate > 0 else {
        logger.error("Audio input not available (sample rate is 0)")
        return
      }

      let streamAnalyzer = SNAudioStreamAnalyzer(format: inputFormat)

      do {
        let classifyRequest = try SNClassifySoundRequest(
          classifierIdentifier: .version1)
        classifyRequest.overlapFactor = 0.5
        try streamAnalyzer.add(classifyRequest, withObserver: self)
        self.request = classifyRequest
      } catch {
        logger.error("Failed to create sound classification request: \(error)")
        return
      }

      self.analyzer = streamAnalyzer
      self.engine = audioEngine

      // Capture a local reference for the tap closure so it doesn't access
      // `self.analyzer` from the audio thread.
      let analyzerRef = streamAnalyzer
      inputNode.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) {
        buffer, time in
        analyzerRef.analyze(buffer, atAudioFramePosition: time.sampleTime)
      }

      do {
        try audioEngine.start()
      } catch {
        logger.error("Failed to start audio engine: \(error)")
        inputNode.removeTap(onBus: 0)
        self.analyzer = nil
        self.engine = nil
        self.request = nil
        return
      }

      _state.withLock { $0.isRunning = true }
      logger.info("Sound classifier started")
    }
  }

  func stop() {
    analysisQueue.async { [self] in
      guard _state.withLock({ $0.isRunning }) else { return }

      cooldownItem?.cancel()
      cooldownItem = nil
      engine?.inputNode.removeTap(onBus: 0)
      engine?.stop()
      analyzer?.removeAllRequests()
      engine = nil
      analyzer = nil
      request = nil

      _state.withLock {
        $0.isRunning = false
        $0.isDetected = false
        $0.lastDetectionTime = nil
      }
      logger.info("Sound classifier stopped")
    }
  }

  /// Reset detection state without stopping the classifier.
  func reset() {
    analysisQueue.async { [self] in
      cooldownItem?.cancel()
      cooldownItem = nil
      let wasDetected = _state.withLock {
        let was = $0.isDetected
        $0.isDetected = false
        $0.lastDetectionTime = nil
        return was
      }
      if wasDetected {
        onSmokeDetected?(false)
      }
    }
  }

  // MARK: - SNResultsObserving

  func request(_ request: any SNRequest, didProduce result: any SNResult) {
    guard let classification = result as? SNClassificationResult else { return }

    let threshold = _state.withLock { $0.confidenceThreshold }

    let smokeDetected = classification.classifications.contains { c in
      Self.smokeIdentifiers.contains(c.identifier) && c.confidence >= threshold
    }

    // Dispatch to analysisQueue so cooldownItem access is serialized.
    guard smokeDetected else { return }
    analysisQueue.async { [self] in
      let shouldNotify = _state.withLock { state -> Bool in
        state.lastDetectionTime = Date()
        if !state.isDetected {
          state.isDetected = true
          return true
        }
        return false
      }
      if shouldNotify {
        logger.info("Smoke alarm sound detected")
        onSmokeDetected?(true)
      }
      // Reset cooldown timer
      cooldownItem?.cancel()
      let cooldownDuration = _state.withLock { $0.cooldown }
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let shouldClear = self._state.withLock { state -> Bool in
          guard state.isDetected else { return false }
          guard let lastDetection = state.lastDetectionTime,
            Date().timeIntervalSince(lastDetection) >= state.cooldown
          else { return false }
          state.isDetected = false
          state.lastDetectionTime = nil
          return true
        }
        if shouldClear {
          self.logger.info("Smoke alarm sound cleared after cooldown")
          self.onSmokeDetected?(false)
        }
      }
      cooldownItem = item
      analysisQueue.asyncAfter(deadline: .now() + cooldownDuration, execute: item)
    }
  }

  func request(_ request: any SNRequest, didFailWithError error: any Error) {
    logger.error("Sound classification failed: \(error)")
  }

  func requestDidComplete(_ request: any SNRequest) {
    logger.info("Sound classification request completed")
  }
}
