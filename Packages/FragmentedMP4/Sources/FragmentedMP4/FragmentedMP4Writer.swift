import CoreMedia
import os

private let logSubsystem = "me.fausak.taylor.Pylo"

// MARK: - Fragment Ring Buffer

/// A completed fMP4 fragment ready for serving via HDS.
public struct MP4Fragment: Sendable {
  public let data: Data
  public let timestamp: CMTime
  public let duration: CMTime
  public let sequenceNumber: Int

  public init(data: Data, timestamp: CMTime, duration: CMTime, sequenceNumber: Int) {
    self.data = data
    self.timestamp = timestamp
    self.duration = duration
    self.sequenceNumber = sequenceNumber
  }
}

/// Thread-safe circular buffer holding the most recent fMP4 fragments for prebuffering.
/// Uses index-based overwrite for O(1) append instead of O(n) removeFirst.
public nonisolated final class FragmentRingBuffer: Sendable {

  private let capacity: Int

  private struct State: Sendable {
    var slots: [MP4Fragment?]
    var writeIndex = 0
    var count = 0
    var nextSequence = 0
  }

  private let state: OSAllocatedUnfairLock<State>

  public init(capacity: Int = 2) {
    self.capacity = capacity
    self.state = OSAllocatedUnfairLock(
      initialState: State(slots: Array(repeating: nil, count: capacity)))
  }

  /// Add a completed fragment to the ring buffer (O(1)).
  public func append(_ fragment: MP4Fragment) {
    state.withLock { state in
      state.slots[state.writeIndex % capacity] = fragment
      state.writeIndex += 1
      state.count = min(state.count + 1, capacity)
    }
  }

  /// Get the next sequence number and advance.
  public func nextSequenceNumber() -> Int {
    state.withLock { state in
      let seq = state.nextSequence
      state.nextSequence += 1
      return seq
    }
  }

  /// Snapshot the current buffer contents in chronological order.
  public func snapshot() -> [MP4Fragment] {
    state.withLock { state in
      guard state.count > 0 else { return [] }
      let startIndex = state.writeIndex - state.count
      return (0..<state.count).compactMap { i in
        state.slots[(startIndex + i) % capacity]
      }
    }
  }

  /// Clear all buffered fragments.
  public func clear() {
    state.withLock { state in
      for i in state.slots.indices { state.slots[i] = nil }
      state.writeIndex = 0
      state.count = 0
      state.nextSequence = 0
    }
  }
}

// MARK: - Fragmented MP4 Writer

/// A buffered video sample extracted from a CMSampleBuffer.
private struct VideoSample {
  let data: Data  // Raw H.264 AVCC data (4-byte length-prefixed NAL units)
  let pts: CMTime  // Presentation timestamp
  let isKeyframe: Bool  // Whether this is a sync (IDR) sample
}

/// Generates fragmented MP4 segments from H.264 sample buffers by manually
/// constructing moof+mdat boxes (ISO 14496-12). AVAssetWriter on iOS does not
/// produce fragmented MP4 regardless of movieFragmentInterval, so we bypass it
/// entirely and build the ISO BMFF boxes from raw CMSampleBuffer data.
public nonisolated final class FragmentedMP4Writer: @unchecked Sendable {

  /// Ring buffer holding completed fragments for HKSV prebuffering.
  public let ringBuffer = FragmentRingBuffer(capacity: 6)

  /// Called when a new fragment is completed.
  /// Wrapped in a Sendable box so OSAllocatedUnfairLock accepts the non-Sendable closure type.
  private struct CallbackBox: @unchecked Sendable {
    var handler: ((MP4Fragment) -> Void)?
  }
  private let _onFragmentReady = OSAllocatedUnfairLock(initialState: CallbackBox())
  public var onFragmentReady: ((MP4Fragment) -> Void)? {
    get { _onFragmentReady.withLockUnchecked { $0.handler } }
    set { _onFragmentReady.withLockUnchecked { $0.handler = newValue } }
  }

  private let logger = Logger(subsystem: logSubsystem, category: "fMP4Writer")

  /// Minimum elapsed time before emitting a fragment at the next keyframe.
  /// Set below the hub's 4000ms fragment limit so we don't overshoot when
  /// keyframes land slightly early (e.g., frame 119 at 3.97s instead of 120 at 4.0s).
  private let fragmentDuration: TimeInterval = 3.5

  /// Video track timescale used in mdhd, tfdt, and trun durations.
  /// 1000 = millisecond precision, matching positron/wyrecam's working HKSV implementation.
  private let videoTimescale: UInt32 = 1000

  // Audio track constants
  private let audioTimescale: UInt32 = 16000
  private let audioFrameDuration: UInt32 = 480

  /// All mutable state protected by a single lock. This replaces the separate audioLock
  /// and unprotected video-side properties to prevent data races when appendVideoSample,
  /// appendAudioSample, configure, and stop are called from different threads.
  private struct WriterState {
    var fps: Int = 30
    var pendingSamples: [VideoSample] = []
    var fragmentStartPTS: CMTime = .invalid
    var accumulatedDecodeTime: UInt64 = 0
    var moofSequenceNumber: UInt32 = 0
    var hasLoggedFirstFragment = false
    var videoFormatDescription: CMFormatDescription?
    var initSegment: Data?
    var includeAudioTrack = false
    var pendingAudioSamples: [Data] = []
    var accumulatedAudioDecodeTime: UInt64 = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: WriterState())

  public init() {}

  /// The initialization segment (ftyp + moov) — manually constructed from the video
  /// format description with H.264 SPS/PPS and AAC codec parameters.
  public var initSegment: Data? {
    state.withLock { $0.initSegment }
  }

  /// Set externally by the capture session when mic + encoder are ready.
  /// Invalidates the cached init segment when changed so it's rebuilt with/without the audio track.
  public var includeAudioTrack: Bool {
    get { state.withLock { $0.includeAudioTrack } }
    set {
      state.withLock { s in
        if s.includeAudioTrack != newValue {
          s.includeAudioTrack = newValue
          s.videoFormatDescription = nil
          s.initSegment = nil
        }
      }
    }
  }

  public func configure(width: Int, height: Int, fps: Int) {
    state.withLock { $0.fps = fps }
  }

  // MARK: - Writing

  /// Append an encoded AAC-ELD frame to be included in the next fragment.
  /// Audio samples are drained when the next video fragment is emitted; if video
  /// keyframes stop arriving, this caps accumulation at ~10s of audio (~330 frames)
  /// to prevent unbounded memory growth.
  public func appendAudioSample(_ encodedFrame: Data) {
    state.withLock { s in
      if s.pendingAudioSamples.count < 340 {
        s.pendingAudioSamples.append(encodedFrame)
      }
    }
  }

  /// Append an encoded H.264 sample buffer to the current fragment.
  public func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Determine if this is a keyframe (sync sample)
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    // Extract raw H.264 data from the CMBlockBuffer
    guard let dataBuffer = sampleBuffer.dataBuffer else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    let status = CMBlockBufferGetDataPointer(
      dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard status == kCMBlockBufferNoErr, let ptr = dataPointer, totalLength > 0 else { return }
    let sampleData = Data(bytes: ptr, count: totalLength)

    // Capture video format description outside the lock (requires the CMSampleBuffer)
    let fmt = CMSampleBufferGetFormatDescription(sampleBuffer)

    // Collect fragments emitted during the lock and notify outside the lock
    // to prevent deadlock if the callback reenters the writer.
    // At most two fragments can be emitted: one from a PTS gap flush, one from a keyframe flush.

    // Check if init segment needs to be built (outside lock since it's heavy)
    let needsInitSegment = state.withLock { s -> Bool in
      s.videoFormatDescription == nil && fmt != nil
    }
    if needsInitSegment, let fmt {
      let includeAudio = state.withLock { $0.includeAudioTrack }
      let initSeg = buildInitSegment(videoFormat: fmt, includeAudio: includeAudio)
      let needsRebuild = state.withLock { s -> Bool in
        // Double-check under lock in case another thread raced us
        guard s.videoFormatDescription == nil else { return false }
        // Re-check includeAudioTrack in case it changed while we were building
        if s.includeAudioTrack != includeAudio { return true }
        s.videoFormatDescription = fmt
        s.initSegment = initSeg
        return false
      }
      if needsRebuild {
        let currentAudio = state.withLock { $0.includeAudioTrack }
        let rebuilt = buildInitSegment(videoFormat: fmt, includeAudio: currentAudio)
        state.withLock { s in
          if s.videoFormatDescription == nil {
            s.videoFormatDescription = fmt
            s.initSegment = rebuilt
          }
        }
      }
    }

    let (gapFragment, keyframeFragment) = state.withLock {
      s -> (MP4Fragment?, MP4Fragment?) in
      var gap: MP4Fragment?
      var kf: MP4Fragment?

      // Detect PTS gaps from capture source transitions (snapshot pause, live stream
      // start/stop). Flush pending samples so fragments don't span transitions — a
      // PTS gap inflates sample durations and causes fragments to exceed the hub's
      // 4000ms fragment limit. Require at least ~1 second of data (30 samples) to
      // avoid emitting tiny fragments from startup jitter.
      if let lastSamplePTS = s.pendingSamples.last?.pts {
        let g = CMTimeGetSeconds(CMTimeSubtract(pts, lastSamplePTS))
        if (g > 0.5 || g < 0) && s.pendingSamples.count >= 30 {
          gap = emitFragment(state: &s)
        } else if g > 0.5 || g < 0 {
          // Gap detected with too few samples — discard to avoid a tiny fragment.
          s.pendingSamples.removeAll()
          s.fragmentStartPTS = .invalid
        }
      }

      // If this is a keyframe and we have enough buffered data, emit a fragment
      if isKeyframe && !s.pendingSamples.isEmpty && s.fragmentStartPTS.isValid {
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, s.fragmentStartPTS))
        if elapsed >= fragmentDuration {
          kf = emitFragment(state: &s)
        }
      }

      // Track fragment start time
      if !s.fragmentStartPTS.isValid {
        s.fragmentStartPTS = pts
      }

      s.pendingSamples.append(VideoSample(data: sampleData, pts: pts, isKeyframe: isKeyframe))
      return (gap, kf)
    }
    // Snapshot handler once to avoid TOCTOU if cleared between dispatches
    let handler = onFragmentReady
    if let gapFragment { handler?(gapFragment) }
    if let keyframeFragment { handler?(keyframeFragment) }
  }

  /// Stop the writer and flush any pending samples as a final fragment.
  ///
  /// Continuity counters (`accumulatedDecodeTime`, `accumulatedAudioDecodeTime`) are
  /// preserved so prebuffered fragments in the ring buffer form a valid continuous fMP4
  /// stream when the writer restarts. The ring buffer itself is NOT cleared — old
  /// fragments are naturally evicted as new ones arrive after restart.
  ///
  /// `videoFormatDescription` and `initSegment` ARE cleared so a fresh init segment
  /// is built on the next `appendVideoSample`, reflecting any changes to resolution or
  /// `includeAudioTrack`. This is safe because the accumulated decode times are
  /// monotonically increasing counters that remain valid across init segment boundaries
  /// — the hub identifies fragments by moof sequence number, not by init segment affinity.
  public func stop() {
    let handler = onFragmentReady
    let flushed: MP4Fragment? = state.withLock { s in
      var result: MP4Fragment?
      if !s.pendingSamples.isEmpty {
        result = emitFragment(state: &s)
      }
      s.fragmentStartPTS = .invalid
      s.hasLoggedFirstFragment = false
      s.pendingAudioSamples.removeAll()
      // Reset format so init segment is rebuilt on next start, reflecting current includeAudioTrack state.
      s.videoFormatDescription = nil
      s.initSegment = nil
      return result
    }
    if let flushed { handler?(flushed) }
  }

  // MARK: - Fragment Construction

  /// Build and emit a moof+mdat fragment from the buffered samples.
  /// Produces a two-track moof when audio samples are available: video traf (track 1)
  /// followed by audio traf (track 2) with real AAC-ELD frames.
  /// Must be called with the lock held (takes inout WriterState).
  /// Returns the completed fragment so the caller can invoke the callback outside the lock.
  @discardableResult
  private func emitFragment(state s: inout WriterState) -> MP4Fragment? {
    guard s.pendingSamples.count >= 1 else { return nil }

    let samples = s.pendingSamples
    s.pendingSamples = []
    let fragStart = s.fragmentStartPTS
    s.fragmentStartPTS = .invalid

    // Drain pending audio samples
    let audioFrames = s.pendingAudioSamples
    s.pendingAudioSamples.removeAll()
    let na = audioFrames.count

    // Compute per-sample durations from PTS deltas (in timescale ticks)
    let timescale = Int64(videoTimescale)
    var durations: [UInt32] = []
    for i in 0..<samples.count {
      if i + 1 < samples.count {
        let delta = CMTimeSubtract(samples[i + 1].pts, samples[i].pts)
        let ticks = CMTimeConvertScale(delta, timescale: Int32(timescale), method: .roundTowardZero)
        durations.append(UInt32(max(ticks.value, 1)))
      } else {
        let d = durations.isEmpty ? UInt32(timescale / Int64(s.fps)) : durations.last!
        durations.append(d)
      }
    }

    let totalTicks = durations.reduce(UInt64(0)) { $0 + UInt64($1) }
    let sizes = samples.map { UInt32($0.data.count) }
    let firstIsKeyframe = samples.first?.isKeyframe ?? false

    s.moofSequenceNumber += 1

    // Pre-compute moof size for data_offset calculation.
    // tfhd: 8(box) + 4(ver/flags) + 4(trackID) + 4(default_sample_flags) = 20
    // tfdt: 8(box) + 4(ver/flags) + 8(baseMediaDecodeTime v1) = 20
    // trun: 8(box) + 4(ver/flags) + 4(sample_count) + 4(data_offset)
    //       + [4(first_sample_flags) if keyframe] + Nv*8(duration+size) = 20+[4]+Nv*8
    // Video traf: 8(traf) + 20(tfhd) + 20(tfdt) + trun = 48 + trunSize
    let nv = samples.count
    // count + offset + [first_sample_flags] + samples
    let trunPayloadSize = 4 + 4 + (firstIsKeyframe ? 4 : 0) + nv * 8
    let trunBoxSize = 8 + 4 + trunPayloadSize  // box header + ver/flags + payload
    let videoTrafSize = 8 + 20 + 20 + trunBoxSize

    // Audio traf: 8(traf) + 24(tfhd) + 20(tfdt) + 20+Na*4(trun) = 72 + Na*4
    let audioTrafSize = na > 0 ? 72 + na * 4 : 0

    let moofSize = 8 + 16 + videoTrafSize + audioTrafSize
    let videoDataOffset = UInt32(moofSize + 8)  // +8 for mdat header

    // mfhd
    var mfhdP = Data()
    Self.putU32BE(&mfhdP, s.moofSequenceNumber)
    let mfhd = Self.mp4FullBox("mfhd", payload: mfhdP)

    // Video traf (track 1): tfhd with default_sample_flags + tfdt + trun
    // tfhd flags 0x20020: default-base-is-moof + default-sample-flags-present
    var vTfhdP = Data()
    Self.putU32BE(&vTfhdP, 1)  // track_ID
    Self.putU32BE(&vTfhdP, 0x0101_0000)  // default_sample_flags (non-sync)
    let vTfhd = Self.mp4FullBox("tfhd", flags: 0x02_0020, payload: vTfhdP)

    var vTfdtP = Data()
    Self.putU32BE(&vTfdtP, UInt32((s.accumulatedDecodeTime >> 32) & 0xFFFF_FFFF))
    Self.putU32BE(&vTfdtP, UInt32(s.accumulatedDecodeTime & 0xFFFF_FFFF))
    let vTfdt = Self.mp4FullBox("tfdt", version: 1, payload: vTfdtP)

    // trun flags: 0x001=data-offset, 0x100=sample-duration, 0x200=sample-size
    // + 0x004=first-sample-flags-present (only when first sample is keyframe)
    let trunFlags: UInt32 = firstIsKeyframe ? 0x000305 : 0x000301
    var vTrunP = Data()
    Self.putU32BE(&vTrunP, UInt32(nv))
    Self.putU32BE(&vTrunP, videoDataOffset)
    if firstIsKeyframe {
      Self.putU32BE(&vTrunP, 0x0200_0000)  // first_sample_flags (sync/keyframe)
    }
    for i in 0..<nv {
      Self.putU32BE(&vTrunP, durations[i])
      Self.putU32BE(&vTrunP, sizes[i])
    }
    let vTrun = Self.mp4FullBox("trun", flags: trunFlags, payload: vTrunP)
    let videoTraf = Self.mp4Box("traf", vTfhd + vTfdt + vTrun)

    // Build audio traf (track 2) if we have audio samples
    var audioTraf = Data()
    var audioMdatPayload = Data()
    if na > 0 {
      // Use Int to avoid UInt32 overflow (silent wrap in release builds).
      let videoMdatSize = sizes.reduce(0) { $0 + Int($1) }
      // past moof + mdat header + video data
      let audioDataOffset = UInt32(moofSize + 8 + videoMdatSize)

      // tfhd flags 0x020028: default-base-is-moof + default-sample-duration + default-sample-flags
      var aTfhdP = Data()
      Self.putU32BE(&aTfhdP, 2)  // track_ID
      Self.putU32BE(&aTfhdP, audioFrameDuration)  // default_sample_duration = 480
      Self.putU32BE(&aTfhdP, 0x0200_0000)  // default_sample_flags (sync)
      let aTfhd = Self.mp4FullBox("tfhd", flags: 0x02_0028, payload: aTfhdP)

      var aTfdtP = Data()
      Self.putU32BE(&aTfdtP, UInt32((s.accumulatedAudioDecodeTime >> 32) & 0xFFFF_FFFF))
      Self.putU32BE(&aTfdtP, UInt32(s.accumulatedAudioDecodeTime & 0xFFFF_FFFF))
      let aTfdt = Self.mp4FullBox("tfdt", version: 1, payload: aTfdtP)

      // trun flags 0x000201: data-offset + sample-size (variable per frame)
      var aTrunP = Data()
      Self.putU32BE(&aTrunP, UInt32(na))
      Self.putU32BE(&aTrunP, audioDataOffset)
      for frame in audioFrames {
        Self.putU32BE(&aTrunP, UInt32(frame.count))
      }
      let aTrun = Self.mp4FullBox("trun", flags: 0x000201, payload: aTrunP)
      audioTraf = Self.mp4Box("traf", aTfhd + aTfdt + aTrun)

      for frame in audioFrames { audioMdatPayload.append(frame) }
    }

    let moofPayload = mfhd + videoTraf + audioTraf
    let moof = Self.mp4Box("moof", moofPayload)

    // Build the complete fragment in a single allocation: moof + mdat header + sample data.
    // This avoids intermediate mdatPayload and mdat Data copies that previously tripled
    // transient memory during fragment construction.
    let mdatPayloadSize = samples.reduce(0) { $0 + $1.data.count } + audioMdatPayload.count
    let mdatBoxSize = mdatPayloadSize + 8
    var fragmentData = Data()
    fragmentData.reserveCapacity(moof.count + mdatBoxSize)
    fragmentData.append(moof)
    // Write mdat box header inline
    Self.putU32BE(&fragmentData, UInt32(mdatBoxSize))
    fragmentData.append(contentsOf: "mdat".utf8)
    for sample in samples { fragmentData.append(sample.data) }
    fragmentData.append(audioMdatPayload)

    // Log first fragment diagnostics
    if !s.hasLoggedFirstFragment {
      let seqNum = s.moofSequenceNumber
      let baseDT = s.accumulatedDecodeTime
      let hasAudio = s.includeAudioTrack
      logger.info(
        "First moof: seq=\(seqNum), samples=\(nv), baseDecodeTime=\(baseDT), totalTicks=\(totalTicks), audioFrames=\(na), audio=\(hasAudio), moof=\(moof.count)B, mdat=\(mdatBoxSize)B"
      )
      s.hasLoggedFirstFragment = true
    }

    // Advance accumulated decode times for next fragment's tfdt
    s.accumulatedDecodeTime += totalTicks
    if na > 0 {
      s.accumulatedAudioDecodeTime += UInt64(na) * UInt64(audioFrameDuration)
    }

    // Compute total duration as CMTime
    let totalDuration: CMTime
    if fragStart.isValid, let lastPTS = samples.last?.pts {
      let delta = CMTimeSubtract(lastPTS, fragStart)
      let lastDur = CMTime(value: Int64(durations.last ?? 0), timescale: Int32(timescale))
      totalDuration = CMTimeAdd(delta, lastDur)
    } else {
      totalDuration = CMTime(seconds: fragmentDuration, preferredTimescale: Int32(timescale))
    }

    let seq = ringBuffer.nextSequenceNumber()
    let fragment = MP4Fragment(
      data: fragmentData, timestamp: fragStart,
      duration: totalDuration, sequenceNumber: seq)
    ringBuffer.append(fragment)

    let durSec = String(format: "%.2f", CMTimeGetSeconds(totalDuration))
    logger.debug(
      "Fragment #\(seq): \(fragmentData.count) bytes, \(nv) samples, audioFrames=\(na), \(durSec)s")
    return fragment
  }

  // MARK: - Init Segment Construction

  /// Build a proper fMP4 initialization segment (ftyp + moov) from the video format
  /// description. AVAssetWriter in fragmented mode produces a minimal moov without
  /// track descriptions, so we construct one manually with H.264 SPS/PPS and AAC config.
  private func buildInitSegment(videoFormat: CMFormatDescription, includeAudio: Bool) -> Data? {
    // Extract H.264 SPS and PPS from the video format description
    var paramCount = 0
    guard
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        videoFormat, parameterSetIndex: 0,
        parameterSetPointerOut: nil, parameterSetSizeOut: nil,
        parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil
      ) == noErr, paramCount >= 2
    else {
      logger.error("buildInitSegment: failed to get H.264 parameter set count")
      return nil
    }

    var spsPtr: UnsafePointer<UInt8>?
    var spsSize = 0
    guard
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        videoFormat, parameterSetIndex: 0,
        parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
      ) == noErr, let spsP = spsPtr, spsSize >= 4
    else {
      logger.error("buildInitSegment: failed to get SPS")
      return nil
    }
    let sps = Data(bytes: spsP, count: spsSize)

    var ppsPtr: UnsafePointer<UInt8>?
    var ppsSize = 0
    guard
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        videoFormat, parameterSetIndex: 1,
        parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
      ) == noErr, let ppsP = ppsPtr
    else {
      logger.error("buildInitSegment: failed to get PPS")
      return nil
    }
    let pps = Data(bytes: ppsP, count: ppsSize)

    let dims = CMVideoFormatDescriptionGetDimensions(videoFormat)
    let width = UInt16(dims.width)
    let height = UInt16(dims.height)

    logger.info(
      "buildInitSegment: \(width)x\(height), SPS=\(sps.count)B, PPS=\(pps.count)B, timescale=\(self.videoTimescale), audio=\(includeAudio)"
    )

    // ftyp box — mp42 major brand matching positron's working HKSV implementation
    var ftypPayload = Data()
    ftypPayload.append(contentsOf: "mp42".utf8)
    Self.putU32BE(&ftypPayload, 1)  // minor_version
    for brand in ["isom", "mp42", "avc1"] {
      ftypPayload.append(contentsOf: brand.utf8)
    }
    let ftyp = Self.mp4Box("ftyp", ftypPayload)

    // mvhd (movie header)
    var mvhdP = Data()
    Self.putU32BE(&mvhdP, 0)  // creation_time
    Self.putU32BE(&mvhdP, 0)  // modification_time
    Self.putU32BE(&mvhdP, 1000)  // timescale
    Self.putU32BE(&mvhdP, 0)  // duration
    Self.putU32BE(&mvhdP, 0x0001_0000)  // rate = 1.0
    Self.putU16BE(&mvhdP, 0x0100)  // volume = 1.0
    mvhdP.append(Data(count: 10))  // reserved
    Self.appendIdentityMatrix(&mvhdP)
    mvhdP.append(Data(count: 24))  // pre_defined
    Self.putU32BE(&mvhdP, includeAudio ? 3 : 2)  // next_track_ID
    let mvhd = Self.mp4FullBox("mvhd", payload: mvhdP)

    let videoTrack = buildVideoTrack(
      trackID: 1, width: width, height: height, sps: sps, pps: pps)

    // mvex (movie extends — required for fragmented MP4)
    // No mehd box — positron's working implementation omits it, and it's optional per ISO 14496-12.
    var mvexContent = Self.buildTrex(trackID: 1)
    if includeAudio {
      mvexContent.append(Self.buildTrex(trackID: 2))
    }
    let mvex = Self.mp4Box("mvex", mvexContent)

    var moovContent = mvhd + videoTrack
    if includeAudio {
      moovContent.append(buildAudioTrack(trackID: 2))
    }
    moovContent.append(mvex)
    let moov = Self.mp4Box("moov", moovContent)

    var result = ftyp
    result.append(moov)
    logger.info("buildInitSegment: \(result.count) bytes")
    return result
  }

  private func buildVideoTrack(
    trackID: UInt32, width: UInt16, height: UInt16, sps: Data, pps: Data
  ) -> Data {
    // tkhd
    var tkhdP = Data()
    Self.putU32BE(&tkhdP, 0)  // creation_time
    Self.putU32BE(&tkhdP, 0)  // modification_time
    Self.putU32BE(&tkhdP, trackID)
    Self.putU32BE(&tkhdP, 0)  // reserved
    Self.putU32BE(&tkhdP, 0)  // duration
    tkhdP.append(Data(count: 8))  // reserved
    Self.putU16BE(&tkhdP, 0)  // layer
    Self.putU16BE(&tkhdP, 0)  // alternate_group
    Self.putU16BE(&tkhdP, 0)  // volume (0 for video)
    Self.putU16BE(&tkhdP, 0)  // reserved
    Self.appendIdentityMatrix(&tkhdP)
    Self.putU32BE(&tkhdP, UInt32(width) << 16)  // width fixed 16.16
    Self.putU32BE(&tkhdP, UInt32(height) << 16)  // height fixed 16.16
    let tkhd = Self.mp4FullBox("tkhd", flags: 7, payload: tkhdP)

    // mdhd
    var mdhdP = Data()
    Self.putU32BE(&mdhdP, 0)  // creation_time
    Self.putU32BE(&mdhdP, 0)  // modification_time
    Self.putU32BE(&mdhdP, videoTimescale)
    Self.putU32BE(&mdhdP, 0)  // duration
    Self.putU16BE(&mdhdP, 0x55C4)  // language: "und"
    Self.putU16BE(&mdhdP, 0)
    let mdhd = Self.mp4FullBox("mdhd", payload: mdhdP)

    // hdlr
    var hdlrP = Data()
    Self.putU32BE(&hdlrP, 0)  // pre_defined
    hdlrP.append(contentsOf: "vide".utf8)
    hdlrP.append(Data(count: 12))  // reserved
    hdlrP.append(contentsOf: "VideoHandler\0".utf8)
    let hdlr = Self.mp4FullBox("hdlr", payload: hdlrP)

    // vmhd
    let vmhd = Self.mp4FullBox("vmhd", flags: 1, payload: Data(count: 8))

    // dinf/dref
    let dinf = Self.buildDinf()

    // stsd with avc1
    let avcC = Self.buildAvcC(sps: sps, pps: pps)
    var avc1P = Data()
    avc1P.append(Data(count: 6))  // reserved
    Self.putU16BE(&avc1P, 1)  // data_reference_index
    avc1P.append(Data(count: 16))  // pre_defined + reserved
    Self.putU16BE(&avc1P, width)
    Self.putU16BE(&avc1P, height)
    Self.putU32BE(&avc1P, 0x0048_0000)  // horiz resolution 72 dpi
    Self.putU32BE(&avc1P, 0x0048_0000)  // vert resolution 72 dpi
    Self.putU32BE(&avc1P, 0)  // reserved
    Self.putU16BE(&avc1P, 1)  // frame_count
    avc1P.append(Data(count: 32))  // compressorname
    Self.putU16BE(&avc1P, 0x0018)  // depth
    Self.putU16BE(&avc1P, 0xFFFF)  // pre_defined = -1
    avc1P.append(avcC)
    let avc1 = Self.mp4Box("avc1", avc1P)

    var stsdP = Data()
    Self.putU32BE(&stsdP, 1)  // entry_count
    stsdP.append(avc1)
    let stsd = Self.mp4FullBox("stsd", payload: stsdP)

    let stbl = Self.mp4Box("stbl", stsd + Self.emptyStbl())
    let minf = Self.mp4Box("minf", vmhd + dinf + stbl)
    let mdia = Self.mp4Box("mdia", mdhd + hdlr + minf)
    return Self.mp4Box("trak", tkhd + mdia)
  }

  private func buildAudioTrack(trackID: UInt32) -> Data {
    // tkhd
    var tkhdP = Data()
    Self.putU32BE(&tkhdP, 0)  // creation_time
    Self.putU32BE(&tkhdP, 0)  // modification_time
    Self.putU32BE(&tkhdP, trackID)
    Self.putU32BE(&tkhdP, 0)  // reserved
    Self.putU32BE(&tkhdP, 0)  // duration
    tkhdP.append(Data(count: 8))  // reserved
    Self.putU16BE(&tkhdP, 0)  // layer
    Self.putU16BE(&tkhdP, 1)  // alternate_group
    Self.putU16BE(&tkhdP, 0x0100)  // volume = 1.0
    Self.putU16BE(&tkhdP, 0)  // reserved
    Self.appendIdentityMatrix(&tkhdP)
    Self.putU32BE(&tkhdP, 0)  // width (0 for audio)
    Self.putU32BE(&tkhdP, 0)  // height (0 for audio)
    let tkhd = Self.mp4FullBox("tkhd", flags: 7, payload: tkhdP)

    // mdhd
    var mdhdP = Data()
    Self.putU32BE(&mdhdP, 0)  // creation_time
    Self.putU32BE(&mdhdP, 0)  // modification_time
    Self.putU32BE(&mdhdP, audioTimescale)  // 16000
    Self.putU32BE(&mdhdP, 0)  // duration
    Self.putU16BE(&mdhdP, 0x55C4)  // language: "und"
    Self.putU16BE(&mdhdP, 0)
    let mdhd = Self.mp4FullBox("mdhd", payload: mdhdP)

    // hdlr
    var hdlrP = Data()
    Self.putU32BE(&hdlrP, 0)  // pre_defined
    hdlrP.append(contentsOf: "soun".utf8)
    hdlrP.append(Data(count: 12))  // reserved
    hdlrP.append(contentsOf: "SoundHandler\0".utf8)
    let hdlr = Self.mp4FullBox("hdlr", payload: hdlrP)

    // smhd (sound media header)
    let smhd = Self.mp4FullBox("smhd", payload: Data(count: 4))  // balance + reserved

    // dinf/dref
    let dinf = Self.buildDinf()

    // stsd with mp4a + esds
    // AudioSpecificConfig for ER AAC-ELD (objectType=39):
    //   objectType(5)=11111(escape), objectTypeExt(6)=000111(39-32=7),
    //   freqIndex(4)=1000(16kHz), channelConfig(4)=0001(mono),
    //   ELDSpecificConfig: frameLengthFlag=1(480), resilience=0000, ldSbrPresent=0,
    //   epConfig=00
    let audioConfig: [UInt8] = [0xF8, 0xF0, 0x30, 0x00]
    let esds = Self.buildEsds(trackID: trackID, audioConfig: Data(audioConfig))
    var mp4aP = Data()
    mp4aP.append(Data(count: 6))  // reserved
    Self.putU16BE(&mp4aP, 1)  // data_reference_index
    mp4aP.append(Data(count: 8))  // reserved
    Self.putU16BE(&mp4aP, 1)  // channel_count
    Self.putU16BE(&mp4aP, 16)  // sample_size (bits)
    Self.putU16BE(&mp4aP, 0)  // compression_id
    Self.putU16BE(&mp4aP, 0)  // packet_size
    Self.putU32BE(&mp4aP, audioTimescale << 16)  // sample_rate fixed 16.16
    mp4aP.append(esds)
    let mp4a = Self.mp4Box("mp4a", mp4aP)

    var stsdP = Data()
    Self.putU32BE(&stsdP, 1)  // entry_count
    stsdP.append(mp4a)
    let stsd = Self.mp4FullBox("stsd", payload: stsdP)

    let stbl = Self.mp4Box("stbl", stsd + Self.emptyStbl())
    let minf = Self.mp4Box("minf", smhd + dinf + stbl)
    let mdia = Self.mp4Box("mdia", mdhd + hdlr + minf)
    return Self.mp4Box("trak", tkhd + mdia)
  }

  /// Encodes a length using MPEG-4 expandable size encoding (ISO 14496-1 §8.3.3).
  /// Sizes 0–127 use 1 byte; larger sizes use continuation bits.
  static func mp4DescriptorLength(_ size: Int) -> Data {
    precondition(size >= 0 && size <= 0x0FFF_FFFF, "Descriptor size out of range")
    if size < 0x80 {
      return Data([UInt8(size)])
    }
    var result = Data()
    var remaining = size
    // Encode in big-endian with continuation bits (MSB set on all but last byte)
    var bytes: [UInt8] = []
    bytes.append(UInt8(remaining & 0x7F))
    remaining >>= 7
    while remaining > 0 {
      bytes.append(0x80 | UInt8(remaining & 0x7F))
      remaining >>= 7
    }
    bytes.reverse()
    result.append(contentsOf: bytes)
    return result
  }

  private static func buildEsds(trackID: UInt32, audioConfig: Data) -> Data {
    // ES_Descriptor
    let asc = audioConfig  // AudioSpecificConfig
    // DecoderSpecificInfo tag (0x05)
    var dsi = Data([0x05])
    dsi.append(mp4DescriptorLength(asc.count))
    dsi.append(asc)

    // DecoderConfigDescriptor tag (0x04)
    var dcd = Data()
    dcd.append(0x40)  // objectTypeIndication = AAC
    dcd.append(0x15)  // streamType = audio (5) << 2 | upstream (0) << 1 | reserved (1)
    dcd.append(contentsOf: [0x00, 0x00, 0x00])  // bufferSizeDB (3 bytes)
    putU32BE(&dcd, 24000)  // maxBitrate
    putU32BE(&dcd, 24000)  // avgBitrate
    dcd.append(dsi)
    var dcdTagged = Data([0x04])
    dcdTagged.append(mp4DescriptorLength(dcd.count))
    dcdTagged.append(dcd)

    // SLConfigDescriptor tag (0x06)
    let slc = Data([0x06, 0x01, 0x02])

    // ES_Descriptor tag (0x03)
    var esd = Data()
    putU16BE(&esd, UInt16(trackID))  // ES_ID
    esd.append(0x00)  // streamDependenceFlag=0, URL_Flag=0, OCRstreamFlag=0, streamPriority=0
    esd.append(dcdTagged)
    esd.append(slc)
    var esdTagged = Data([0x03])
    esdTagged.append(mp4DescriptorLength(esd.count))
    esdTagged.append(esd)

    // esds box (fullbox version 0)
    return mp4FullBox("esds", payload: esdTagged)
  }

  // MARK: - MP4 Box Helpers

  private static func mp4Box(_ type: String, _ payload: Data) -> Data {
    precondition(
      payload.count + 8 <= UInt32.max,
      "mp4Box payload too large for 32-bit box size (\(payload.count) bytes)")
    let size = UInt32(payload.count + 8)
    var data = Data()
    putU32BE(&data, size)
    data.append(contentsOf: type.utf8.prefix(4))
    data.append(payload)
    return data
  }

  private static func mp4FullBox(
    _ type: String, version: UInt8 = 0, flags: UInt32 = 0, payload: Data
  ) -> Data {
    var inner = Data()
    inner.append(version)
    inner.append(UInt8((flags >> 16) & 0xFF))
    inner.append(UInt8((flags >> 8) & 0xFF))
    inner.append(UInt8(flags & 0xFF))
    inner.append(payload)
    return mp4Box(type, inner)
  }

  private static func putU32BE(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private static func putU16BE(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private static func appendIdentityMatrix(_ data: inout Data) {
    putU32BE(&data, 0x0001_0000)
    putU32BE(&data, 0)
    putU32BE(&data, 0)
    putU32BE(&data, 0)
    putU32BE(&data, 0x0001_0000)
    putU32BE(&data, 0)
    putU32BE(&data, 0)
    putU32BE(&data, 0)
    putU32BE(&data, 0x4000_0000)
  }

  private static func buildDinf() -> Data {
    let urlBox = mp4FullBox("url ", flags: 1, payload: Data())
    var drefP = Data()
    putU32BE(&drefP, 1)  // entry_count
    drefP.append(urlBox)
    let dref = mp4FullBox("dref", payload: drefP)
    return mp4Box("dinf", dref)
  }

  /// Empty stts + stsc + stsz + stco tables (required for valid stbl, empty for fragmented MP4).
  private static func emptyStbl() -> Data {
    let stts = mp4FullBox("stts", payload: Data(count: 4))
    let stsc = mp4FullBox("stsc", payload: Data(count: 4))
    var stszP = Data()
    putU32BE(&stszP, 0)  // sample_size
    putU32BE(&stszP, 0)  // sample_count
    let stsz = mp4FullBox("stsz", payload: stszP)
    let stco = mp4FullBox("stco", payload: Data(count: 4))
    return stts + stsc + stsz + stco
  }

  private static func buildAvcC(sps: Data, pps: Data) -> Data {
    var p = Data()
    p.append(1)  // configurationVersion
    p.append(sps[1])  // AVCProfileIndication
    p.append(sps[2])  // profile_compatibility
    p.append(sps[3])  // AVCLevelIndication
    p.append(0xFF)  // lengthSizeMinusOne=3 | reserved
    p.append(0xE1)  // numSPS=1 | reserved
    putU16BE(&p, UInt16(sps.count))
    p.append(sps)
    p.append(1)  // numPPS
    putU16BE(&p, UInt16(pps.count))
    p.append(pps)
    return mp4Box("avcC", p)
  }

  private static func buildTrex(trackID: UInt32) -> Data {
    var p = Data()
    putU32BE(&p, trackID)
    putU32BE(&p, 1)  // default_sample_description_index
    putU32BE(&p, 0)  // default_sample_duration
    putU32BE(&p, 0)  // default_sample_size
    putU32BE(&p, 0)  // default_sample_flags
    return mp4FullBox("trex", payload: p)
  }
}
