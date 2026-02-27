import AVFoundation
import CoreMedia
import os

// MARK: - Fragment Ring Buffer

/// A completed fMP4 fragment ready for serving via HDS.
struct MP4Fragment {
  let data: Data
  let timestamp: CMTime
  let duration: CMTime
  let sequenceNumber: Int
}

/// Thread-safe circular buffer holding the most recent fMP4 fragments for prebuffering.
nonisolated final class FragmentRingBuffer {

  private let capacity: Int

  private struct State {
    var fragments: [MP4Fragment] = []
    var nextSequence = 0
  }

  private let state: OSAllocatedUnfairLock<State>

  init(capacity: Int = 2) {
    self.capacity = capacity
    self.state = OSAllocatedUnfairLock(initialState: State())
  }

  /// Add a completed fragment to the ring buffer.
  func append(_ fragment: MP4Fragment) {
    state.withLock { state in
      if state.fragments.count >= capacity {
        state.fragments.removeFirst()
      }
      state.fragments.append(fragment)
    }
  }

  /// Get the next sequence number and advance.
  func nextSequenceNumber() -> Int {
    state.withLock { state in
      let seq = state.nextSequence
      state.nextSequence += 1
      return seq
    }
  }

  /// Snapshot the current buffer contents (for serving after motion trigger).
  func snapshot() -> [MP4Fragment] {
    state.withLock { $0.fragments }
  }

  /// Clear all buffered fragments.
  func clear() {
    state.withLock { state in
      state.fragments.removeAll()
      state.nextSequence = 0
    }
  }
}

// MARK: - Fragmented MP4 Writer

/// Generates fragmented MP4 segments from H.264 sample buffers using AVAssetWriter.
/// Each segment is a ~4-second fMP4 fragment stored in the ring buffer for HKSV prebuffering.
nonisolated final class FragmentedMP4Writer: @unchecked Sendable {

  /// Ring buffer holding completed fragments for HKSV prebuffering.
  let ringBuffer = FragmentRingBuffer(capacity: 3)

  /// Called when a new fragment is completed.
  var onFragmentReady: ((MP4Fragment) -> Void)?

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "fMP4Writer")

  // Configuration
  private var videoWidth: Int = 1920
  private var videoHeight: Int = 1080
  private var fps: Int = 30

  // Writer state
  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var outputURL: URL?
  private var fragmentStartTime: CMTime = .invalid
  private var lastVideoTime: CMTime = .invalid
  private var sampleCount = 0
  private var isStarted = false

  /// Target fragment duration in seconds.
  private let fragmentDuration: TimeInterval = 4.0

  /// The initialization segment (ftyp + moov) — generated once from the first fragment.
  private(set) var initSegment: Data?

  // Temp directory for fragment files
  private static let tempDir: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hksv-fragments")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  func configure(width: Int, height: Int, fps: Int) {
    self.videoWidth = width
    self.videoHeight = height
    self.fps = fps
  }

  // MARK: - Writing

  /// Append an encoded H.264 sample buffer to the current fragment.
  func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Check if we need to start a new fragment
    if !isStarted {
      let fmt = CMSampleBufferGetFormatDescription(sampleBuffer)
      startNewFragment(at: pts, formatDescription: fmt)
    }

    // Check if the current fragment has reached the target duration
    if fragmentStartTime.isValid {
      let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, fragmentStartTime))
      if elapsed >= fragmentDuration {
        // Check if this is a keyframe — only split on keyframes
        let attachments =
          CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
          as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        if isKeyframe {
          finishCurrentFragment()
          let fmt = CMSampleBufferGetFormatDescription(sampleBuffer)
          startNewFragment(at: pts, formatDescription: fmt)
        }
      }
    }

    guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
    videoInput.append(sampleBuffer)
    lastVideoTime = pts
    sampleCount += 1
  }

  /// Append an audio sample buffer to the current fragment.
  func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
    guard isStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
    audioInput.append(sampleBuffer)
  }

  /// Stop the writer and finalize any in-progress fragment.
  func stop() {
    finishCurrentFragment()
    isStarted = false
  }

  // MARK: - Fragment Lifecycle

  private func startNewFragment(at time: CMTime, formatDescription: CMFormatDescription? = nil) {
    let filename = "fragment-\(ProcessInfo.processInfo.globallyUniqueString).mp4"
    let url = Self.tempDir.appendingPathComponent(filename)

    do {
      let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

      // Video input — pass-through pre-encoded H.264 (outputSettings: nil)
      let vInput = AVAssetWriterInput(
        mediaType: .video, outputSettings: nil, sourceFormatHint: formatDescription)
      vInput.expectsMediaDataInRealTime = true
      if writer.canAdd(vInput) { writer.add(vInput) }

      // Audio input — AAC-LC
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 24000,
        AVEncoderBitRateKey: 64000,
      ]
      let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      aInput.expectsMediaDataInRealTime = true
      if writer.canAdd(aInput) { writer.add(aInput) }

      // Configure for fragmented output
      writer.movieFragmentInterval = CMTime(seconds: fragmentDuration, preferredTimescale: 600)
      writer.shouldOptimizeForNetworkUse = false

      writer.startWriting()
      writer.startSession(atSourceTime: time)

      self.assetWriter = writer
      self.videoInput = vInput
      self.audioInput = aInput
      self.outputURL = url
      self.fragmentStartTime = time
      self.sampleCount = 0
      self.isStarted = true

    } catch {
      logger.error("Failed to create AVAssetWriter: \(error)")
    }
  }

  private func finishCurrentFragment() {
    guard let writer = assetWriter, let url = outputURL else { return }

    videoInput?.markAsFinished()
    audioInput?.markAsFinished()

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)

    guard writer.status == .completed else {
      if let error = writer.error {
        logger.error("AVAssetWriter failed: \(error)")
      }
      cleanup(url: url)
      return
    }

    // Read the completed fragment
    guard let fragmentData = try? Data(contentsOf: url) else {
      logger.error("Failed to read fragment file")
      cleanup(url: url)
      return
    }

    let duration =
      lastVideoTime.isValid && fragmentStartTime.isValid
      ? CMTimeSubtract(lastVideoTime, fragmentStartTime)
      : CMTime(seconds: fragmentDuration, preferredTimescale: 600)

    let seq = ringBuffer.nextSequenceNumber()
    let fragment = MP4Fragment(
      data: fragmentData,
      timestamp: fragmentStartTime,
      duration: duration,
      sequenceNumber: seq
    )

    // Extract init segment from the first fragment if needed
    if initSegment == nil {
      initSegment = extractInitSegment(from: fragmentData)
    }

    ringBuffer.append(fragment)
    onFragmentReady?(fragment)

    logger.debug(
      "Fragment #\(seq) complete: \(fragmentData.count) bytes, \(String(format: "%.1f", CMTimeGetSeconds(duration)))s"
    )

    cleanup(url: url)

    // Reset state
    assetWriter = nil
    videoInput = nil
    audioInput = nil
    outputURL = nil
    fragmentStartTime = .invalid
    lastVideoTime = .invalid
  }

  private func cleanup(url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Init Segment Extraction

  /// Extract the initialization segment (ftyp + moov boxes) from a complete fMP4 file.
  /// These boxes appear at the start of the file before the first moof/mdat pair.
  private func extractInitSegment(from data: Data) -> Data? {
    var offset = 0
    var initEnd = 0

    while offset + 8 <= data.count {
      let size =
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
        | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
      let type = String(bytes: data[offset + 4..<offset + 8], encoding: .ascii)

      guard size > 0 else { break }

      if type == "ftyp" || type == "moov" {
        initEnd = offset + size
      } else if type == "moof" || type == "mdat" {
        // We've reached the media data; init segment is everything before this
        break
      }

      offset += size
    }

    guard initEnd > 0 else { return nil }
    return Data(data[0..<initEnd])
  }
}
