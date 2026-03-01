import AudioToolbox
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

/// A buffered video sample extracted from a CMSampleBuffer.
private struct VideoSample {
  let data: Data        // Raw H.264 AVCC data (4-byte length-prefixed NAL units)
  let pts: CMTime       // Presentation timestamp
  let isKeyframe: Bool  // Whether this is a sync (IDR) sample
}

/// Generates fragmented MP4 segments from H.264 sample buffers by manually
/// constructing moof+mdat boxes (ISO 14496-12). AVAssetWriter on iOS does not
/// produce fragmented MP4 regardless of movieFragmentInterval, so we bypass it
/// entirely and build the ISO BMFF boxes from raw CMSampleBuffer data.
nonisolated final class FragmentedMP4Writer: @unchecked Sendable {

  /// Ring buffer holding completed fragments for HKSV prebuffering.
  let ringBuffer = FragmentRingBuffer(capacity: 6)

  /// Called when a new fragment is completed.
  var onFragmentReady: ((MP4Fragment) -> Void)?

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "fMP4Writer")

  // Configuration
  private var videoWidth: Int = 1920
  private var videoHeight: Int = 1080
  private var fps: Int = 30

  /// Minimum elapsed time before emitting a fragment at the next keyframe.
  /// Set below the hub's 4000ms fragment limit so we don't overshoot when
  /// keyframes land slightly early (e.g., frame 119 at 3.97s instead of 120 at 4.0s).
  private let fragmentDuration: TimeInterval = 3.5

  /// The initialization segment (ftyp + moov) — manually constructed from the video
  /// format description with H.264 SPS/PPS and AAC codec parameters.
  private(set) var initSegment: Data?

  /// Video format description (contains H.264 SPS/PPS) captured from the first sample.
  private var videoFormatDescription: CMFormatDescription?
  /// Video track timescale used in mdhd, tfdt, and trun durations.
  /// Fixed at 600 (Apple's standard for MP4/QuickTime) rather than the source's
  /// nanosecond timescale (1,000,000,000) which some parsers may not handle.
  private let videoTimescale: UInt32 = 600

  // Manual fragment construction state
  private var pendingSamples: [VideoSample] = []
  private var fragmentStartPTS: CMTime = .invalid
  /// Accumulated decode time in timescale ticks across all emitted fragments (for tfdt).
  private var accumulatedDecodeTime: UInt64 = 0
  /// Global moof sequence number (ISO 14496-12 §8.8.5).
  private var moofSequenceNumber: UInt32 = 0
  /// Whether the first fragment has been logged for diagnostics.
  private var hasLoggedFirstFragment = false

  // Audio track (AAC-ELD silent filler matching hub's SelectedCameraRecordingConfig)
  // Disabled: silent 2-byte AAC-ELD frames may be invalid. Re-enable once we have
  // real microphone audio or a validated silence frame.
  private let includeAudioTrack = false
  private let audioTimescale: UInt32 = 16000  // AAC-ELD sample rate
  private let audioFrameDuration: UInt32 = 480  // AAC-ELD frame size (samples)
  /// A single encoded AAC-ELD silence frame, cached for reuse in every fragment.
  private var silentAudioFrame: Data?
  /// Accumulated audio decode time in audio timescale ticks across all emitted fragments.
  private var accumulatedAudioDecodeTime: UInt64 = 0

  func configure(width: Int, height: Int, fps: Int) {
    self.videoWidth = width
    self.videoHeight = height
    self.fps = fps
  }

  // MARK: - Silent Audio Setup

  /// Generate a single silent AAC-ELD frame using AudioToolbox's AudioConverter.
  /// Called lazily from buildInitSegment so the audio track is ready before the first fragment.
  private func setupSilentAudio() {
    guard silentAudioFrame == nil else { return }

    var srcDesc = AudioStreamBasicDescription(
      mSampleRate: Float64(audioTimescale),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    var dstDesc = AudioStreamBasicDescription(
      mSampleRate: Float64(audioTimescale),
      mFormatID: kAudioFormatMPEG4AAC_ELD,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: UInt32(audioFrameDuration),
      mBytesPerFrame: 0,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 0,
      mReserved: 0
    )

    var converter: AudioConverterRef?
    guard AudioConverterNew(&srcDesc, &dstDesc, &converter) == noErr,
      let conv = converter
    else {
      logger.warning("Failed to create AAC-ELD encoder for silent audio")
      return
    }
    defer { AudioConverterDispose(conv) }

    var bitrate: UInt32 = 24000
    AudioConverterSetProperty(
      conv, kAudioConverterEncodeBitRate,
      UInt32(MemoryLayout<UInt32>.size), &bitrate)

    // Feed silence (zero-filled PCM) until the encoder produces output.
    // AAC-ELD may require 1-2 priming frames before generating output.
    let frameSizeBytes = Int(audioFrameDuration) * 4  // 480 Float32 samples
    let silenceBytes = [UInt8](repeating: 0, count: frameSizeBytes)
    let outputBufSize: UInt32 = 2048
    let outputBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(outputBufSize))
    defer { outputBuf.deallocate() }

    for _ in 0..<10 {
      var packetCount: UInt32 = 1
      var outputList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 1, mDataByteSize: outputBufSize, mData: outputBuf))
      var packetDesc = AudioStreamPacketDescription()

      var consumed = false
      let status: OSStatus = silenceBytes.withUnsafeBufferPointer { srcBuf in
        var ctx = (ptr: srcBuf.baseAddress!, size: UInt32(frameSizeBytes), done: consumed)
        return withUnsafeMutablePointer(to: &ctx) { ctxPtr in
          AudioConverterFillComplexBuffer(
            conv,
            { (_, ioCount, ioData, _, inUser) -> OSStatus in
              guard let user = inUser else { ioCount.pointee = 0; return noErr }
              let c = user.assumingMemoryBound(
                to: (ptr: UnsafePointer<UInt8>, size: UInt32, done: Bool).self)
              if c.pointee.done { ioCount.pointee = 0; return noErr }
              c.pointee.done = true
              ioCount.pointee = UInt32(c.pointee.size / 4)
              ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: c.pointee.ptr)
              ioData.pointee.mBuffers.mDataByteSize = c.pointee.size
              ioData.pointee.mBuffers.mNumberChannels = 1
              return noErr
            },
            ctxPtr, &packetCount, &outputList, &packetDesc)
        }
      }
      consumed = true  // prevent reuse warning

      guard status == noErr else { break }
      let outSize = Int(outputList.mBuffers.mDataByteSize)
      if outSize > 0 {
        silentAudioFrame = Data(bytes: outputBuf, count: outSize)
        logger.info("Silent AAC-ELD frame: \(outSize) bytes")
        break
      }
    }

    if silentAudioFrame == nil {
      logger.warning("Failed to generate silent AAC-ELD frame")
    }
  }

  // MARK: - Writing

  /// Append an encoded H.264 sample buffer to the current fragment.
  func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Capture video format description and eagerly build init segment
    if videoFormatDescription == nil,
      let fmt = CMSampleBufferGetFormatDescription(sampleBuffer)
    {
      videoFormatDescription = fmt
      initSegment = buildInitSegment(videoFormat: fmt)
    }

    // Determine if this is a keyframe (sync sample)
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    // If this is a keyframe and we have enough buffered data, emit a fragment
    if isKeyframe && !pendingSamples.isEmpty && fragmentStartPTS.isValid {
      let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, fragmentStartPTS))
      if elapsed >= fragmentDuration {
        emitFragment()
      }
    }

    // Extract raw H.264 data from the CMBlockBuffer
    guard let dataBuffer = sampleBuffer.dataBuffer else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    let status = CMBlockBufferGetDataPointer(
      dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard status == kCMBlockBufferNoErr, let ptr = dataPointer, totalLength > 0 else { return }
    let sampleData = Data(bytes: ptr, count: totalLength)

    // Track fragment start time
    if !fragmentStartPTS.isValid {
      fragmentStartPTS = pts
    }

    pendingSamples.append(VideoSample(data: sampleData, pts: pts, isKeyframe: isKeyframe))
  }

  /// Append an audio sample buffer (not used — silent AAC-ELD is generated automatically).
  func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
    // Silent audio is auto-generated in emitFragment(). Real microphone audio
    // could be mixed in here in the future.
  }

  /// Stop the writer and flush any pending samples as a final fragment.
  func stop() {
    if !pendingSamples.isEmpty {
      emitFragment()
    }
    fragmentStartPTS = .invalid
    accumulatedDecodeTime = 0
    accumulatedAudioDecodeTime = 0
    moofSequenceNumber = 0
    hasLoggedFirstFragment = false
  }

  // MARK: - Fragment Construction

  /// Build and emit a moof+mdat fragment from the buffered samples.
  /// Produces a two-track moof when silent audio is available: video traf (track 1)
  /// followed by audio traf (track 2) with AAC-ELD silence frames.
  private func emitFragment() {
    guard pendingSamples.count >= 1 else { return }

    let samples = pendingSamples
    pendingSamples = []
    let fragStart = fragmentStartPTS
    fragmentStartPTS = .invalid

    // Compute per-sample durations from PTS deltas (in timescale ticks)
    let timescale = Int64(videoTimescale)
    var durations: [UInt32] = []
    for i in 0..<samples.count {
      if i + 1 < samples.count {
        let delta = CMTimeSubtract(samples[i + 1].pts, samples[i].pts)
        let ticks = CMTimeConvertScale(delta, timescale: Int32(timescale), method: .roundTowardZero)
        durations.append(UInt32(max(ticks.value, 1)))
      } else {
        let d = durations.isEmpty ? UInt32(timescale / Int64(fps)) : durations.last!
        durations.append(d)
      }
    }

    let totalTicks = durations.reduce(UInt64(0)) { $0 + UInt64($1) }
    let sizes = samples.map { UInt32($0.data.count) }
    let sampleFlags: [UInt32] = samples.map { sample in
      sample.isKeyframe ? 0x0200_0000 : 0x0101_0000
    }

    moofSequenceNumber += 1

    // Audio: compute silent frames to cover this fragment's duration
    let hasAudio = includeAudioTrack && silentAudioFrame != nil
    let audioFrameCount: Int
    let silentFrameSize: UInt32
    if hasAudio {
      let audioTicks = totalTicks * UInt64(audioTimescale) / UInt64(videoTimescale)
      audioFrameCount = max(1, Int(audioTicks / UInt64(audioFrameDuration)))
      silentFrameSize = UInt32(silentAudioFrame!.count)
    } else {
      audioFrameCount = 0
      silentFrameSize = 0
    }

    // Pre-compute moof size for data_offset calculation.
    // Video traf: traf(8) + tfhd(16) + tfdt(20) + trun(20 + Nv*12) = 64 + Nv*12
    // Audio traf: traf(8) + tfhd(28) + tfdt(20) + trun(20) = 76  (all defaults, no per-sample)
    // moof: header(8) + mfhd(16) + videoTraf + audioTraf
    let nv = samples.count
    let audioTrafSize = hasAudio ? 76 : 0
    let moofSize = 8 + 16 + (64 + nv * 12) + audioTrafSize
    let totalVideoBytes = samples.reduce(0) { $0 + $1.data.count }
    let videoDataOffset = UInt32(moofSize + 8)  // +8 for mdat header
    let audioDataOffset = UInt32(moofSize + 8 + totalVideoBytes)

    // mfhd
    var mfhdP = Data()
    Self.putU32BE(&mfhdP, moofSequenceNumber)
    let mfhd = Self.mp4FullBox("mfhd", payload: mfhdP)

    // Video traf (track 1): tfhd + tfdt + trun with per-sample entries
    var vTfhdP = Data()
    Self.putU32BE(&vTfhdP, 1)
    let vTfhd = Self.mp4FullBox("tfhd", flags: 0x02_0000, payload: vTfhdP)

    var vTfdtP = Data()
    Self.putU32BE(&vTfdtP, UInt32((accumulatedDecodeTime >> 32) & 0xFFFF_FFFF))
    Self.putU32BE(&vTfdtP, UInt32(accumulatedDecodeTime & 0xFFFF_FFFF))
    let vTfdt = Self.mp4FullBox("tfdt", version: 1, payload: vTfdtP)

    var vTrunP = Data()
    Self.putU32BE(&vTrunP, UInt32(nv))
    Self.putU32BE(&vTrunP, videoDataOffset)
    for i in 0..<nv {
      Self.putU32BE(&vTrunP, durations[i])
      Self.putU32BE(&vTrunP, sizes[i])
      Self.putU32BE(&vTrunP, sampleFlags[i])
    }
    let vTrun = Self.mp4FullBox("trun", flags: 0x000701, payload: vTrunP)
    let videoTraf = Self.mp4Box("traf", vTfhd + vTfdt + vTrun)

    // Audio traf (track 2): defaults in tfhd, minimal trun (data-offset only)
    var audioTraf = Data()
    if hasAudio {
      // tfhd flags 0x020038: default-base-is-moof | default-sample-duration |
      //                       default-sample-size | default-sample-flags
      var aTfhdP = Data()
      Self.putU32BE(&aTfhdP, 2)  // trackID
      Self.putU32BE(&aTfhdP, audioFrameDuration)  // default_sample_duration
      Self.putU32BE(&aTfhdP, silentFrameSize)  // default_sample_size
      Self.putU32BE(&aTfhdP, 0x0200_0000)  // default_sample_flags (sync)
      let aTfhd = Self.mp4FullBox("tfhd", flags: 0x02_0038, payload: aTfhdP)

      var aTfdtP = Data()
      Self.putU32BE(&aTfdtP, UInt32((accumulatedAudioDecodeTime >> 32) & 0xFFFF_FFFF))
      Self.putU32BE(&aTfdtP, UInt32(accumulatedAudioDecodeTime & 0xFFFF_FFFF))
      let aTfdt = Self.mp4FullBox("tfdt", version: 1, payload: aTfdtP)

      // trun flags 0x000001: data-offset only (durations/sizes/flags from tfhd defaults)
      var aTrunP = Data()
      Self.putU32BE(&aTrunP, UInt32(audioFrameCount))
      Self.putU32BE(&aTrunP, audioDataOffset)
      let aTrun = Self.mp4FullBox("trun", flags: 0x00_0001, payload: aTrunP)

      audioTraf = Self.mp4Box("traf", aTfhd + aTfdt + aTrun)
    }

    let moof = Self.mp4Box("moof", mfhd + videoTraf + audioTraf)

    // mdat: video sample data followed by silent audio frames
    var mdatPayload = Data()
    for sample in samples { mdatPayload.append(sample.data) }
    if hasAudio, let frame = silentAudioFrame {
      for _ in 0..<audioFrameCount { mdatPayload.append(frame) }
    }
    let mdat = Self.mp4Box("mdat", mdatPayload)

    var fragmentData = moof
    fragmentData.append(mdat)

    // Log first fragment diagnostics
    if !hasLoggedFirstFragment {
      let audioInfo = hasAudio ? ", audioFrames=\(audioFrameCount)" : ""
      logger.info(
        "First moof: seq=\(self.moofSequenceNumber), samples=\(nv)\(audioInfo), baseDecodeTime=\(self.accumulatedDecodeTime), totalTicks=\(totalTicks), moof=\(moof.count)B, mdat=\(mdat.count)B"
      )
      hasLoggedFirstFragment = true
    }

    // Advance accumulated decode times for next fragment's tfdt
    accumulatedDecodeTime += totalTicks
    if hasAudio {
      accumulatedAudioDecodeTime += UInt64(audioFrameCount) * UInt64(audioFrameDuration)
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
    onFragmentReady?(fragment)

    let durSec = String(format: "%.2f", CMTimeGetSeconds(totalDuration))
    logger.debug("Fragment #\(seq): \(fragmentData.count) bytes, \(nv) samples, \(durSec)s")
  }

  // MARK: - Init Segment Construction

  /// Build a proper fMP4 initialization segment (ftyp + moov) from the video format
  /// description. AVAssetWriter in fragmented mode produces a minimal moov without
  /// track descriptions, so we construct one manually with H.264 SPS/PPS and AAC config.
  private func buildInitSegment(videoFormat: CMFormatDescription) -> Data? {
    // Extract H.264 SPS and PPS from the video format description
    var paramCount = 0
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      videoFormat, parameterSetIndex: 0,
      parameterSetPointerOut: nil, parameterSetSizeOut: nil,
      parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil
    ) == noErr, paramCount >= 2 else {
      logger.error("buildInitSegment: failed to get H.264 parameter set count")
      return nil
    }

    var spsPtr: UnsafePointer<UInt8>?
    var spsSize = 0
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      videoFormat, parameterSetIndex: 0,
      parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
      parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
    ) == noErr, let spsP = spsPtr, spsSize >= 4 else {
      logger.error("buildInitSegment: failed to get SPS")
      return nil
    }
    let sps = Data(bytes: spsP, count: spsSize)

    var ppsPtr: UnsafePointer<UInt8>?
    var ppsSize = 0
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      videoFormat, parameterSetIndex: 1,
      parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
      parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
    ) == noErr, let ppsP = ppsPtr else {
      logger.error("buildInitSegment: failed to get PPS")
      return nil
    }
    let pps = Data(bytes: ppsP, count: ppsSize)

    let dims = CMVideoFormatDescriptionGetDimensions(videoFormat)
    let width = UInt16(dims.width)
    let height = UInt16(dims.height)

    // Generate silent AAC-ELD frame for audio track (if enabled)
    if includeAudioTrack { setupSilentAudio() }
    let hasAudio = includeAudioTrack && silentAudioFrame != nil

    logger.info(
      "buildInitSegment: \(width)x\(height), SPS=\(sps.count)B, PPS=\(pps.count)B, timescale=\(self.videoTimescale), audio=\(hasAudio)"
    )

    // ftyp box
    var ftypPayload = Data()
    ftypPayload.append(contentsOf: Array("isom".utf8))
    Self.putU32BE(&ftypPayload, 0x200)
    for brand in ["isom", "iso2", "avc1", "mp41"] {
      ftypPayload.append(contentsOf: Array(brand.utf8))
    }
    let ftyp = Self.mp4Box("ftyp", ftypPayload)

    // mvhd (movie header)
    var mvhdP = Data()
    Self.putU32BE(&mvhdP, 0)  // creation_time
    Self.putU32BE(&mvhdP, 0)  // modification_time
    Self.putU32BE(&mvhdP, 600)  // timescale
    Self.putU32BE(&mvhdP, 0)  // duration
    Self.putU32BE(&mvhdP, 0x0001_0000)  // rate = 1.0
    Self.putU16BE(&mvhdP, 0x0100)  // volume = 1.0
    mvhdP.append(Data(count: 10))  // reserved
    Self.appendIdentityMatrix(&mvhdP)
    mvhdP.append(Data(count: 24))  // pre_defined
    Self.putU32BE(&mvhdP, hasAudio ? 3 : 2)  // next_track_ID
    let mvhd = Self.mp4FullBox("mvhd", payload: mvhdP)

    let videoTrack = buildVideoTrack(
      trackID: 1, width: width, height: height, sps: sps, pps: pps)

    // mvex (movie extends — required for fragmented MP4)
    var mvexContent = Self.buildTrex(trackID: 1)
    var tracks = videoTrack
    if hasAudio {
      tracks.append(buildAudioTrack(trackID: 2))
      mvexContent.append(Self.buildTrex(trackID: 2))
    }
    let mvex = Self.mp4Box("mvex", mvexContent)

    let moov = Self.mp4Box("moov", mvhd + tracks + mvex)

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
    let tkhd = Self.mp4FullBox("tkhd", flags: 3, payload: tkhdP)

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
    hdlrP.append(contentsOf: Array("vide".utf8))
    hdlrP.append(Data(count: 12))  // reserved
    hdlrP.append(contentsOf: Array("VideoHandler\0".utf8))
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
    let sampleRate = audioTimescale  // 16000 for AAC-ELD
    let channels: UInt16 = 1

    // tkhd
    var tkhdP = Data()
    Self.putU32BE(&tkhdP, 0)
    Self.putU32BE(&tkhdP, 0)
    Self.putU32BE(&tkhdP, trackID)
    Self.putU32BE(&tkhdP, 0)  // reserved
    Self.putU32BE(&tkhdP, 0)  // duration
    tkhdP.append(Data(count: 8))
    Self.putU16BE(&tkhdP, 0)  // layer
    Self.putU16BE(&tkhdP, 1)  // alternate_group
    Self.putU16BE(&tkhdP, 0x0100)  // volume = 1.0
    Self.putU16BE(&tkhdP, 0)
    Self.appendIdentityMatrix(&tkhdP)
    Self.putU32BE(&tkhdP, 0)  // width
    Self.putU32BE(&tkhdP, 0)  // height
    let tkhd = Self.mp4FullBox("tkhd", flags: 3, payload: tkhdP)

    // mdhd
    var mdhdP = Data()
    Self.putU32BE(&mdhdP, 0)
    Self.putU32BE(&mdhdP, 0)
    Self.putU32BE(&mdhdP, sampleRate)  // timescale = sample rate
    Self.putU32BE(&mdhdP, 0)
    Self.putU16BE(&mdhdP, 0x55C4)  // "und"
    Self.putU16BE(&mdhdP, 0)
    let mdhd = Self.mp4FullBox("mdhd", payload: mdhdP)

    // hdlr
    var hdlrP = Data()
    Self.putU32BE(&hdlrP, 0)
    hdlrP.append(contentsOf: Array("soun".utf8))
    hdlrP.append(Data(count: 12))
    hdlrP.append(contentsOf: Array("SoundHandler\0".utf8))
    let hdlr = Self.mp4FullBox("hdlr", payload: hdlrP)

    // smhd
    let smhd = Self.mp4FullBox("smhd", payload: Data(count: 4))

    // dinf/dref
    let dinf = Self.buildDinf()

    // stsd with mp4a — AAC-ELD AudioSpecificConfig:
    // objectType=23(ELD), freqIndex=8(16kHz), channelConfig=1(mono),
    // frameLengthFlag=0(480), resilience=0000, ldSbr=0, epConfig=00
    let aacEldConfig = Data([0xBC, 0x10, 0x00])
    let esds = Self.buildEsds(trackID: trackID, audioConfig: aacEldConfig)
    var mp4aP = Data()
    mp4aP.append(Data(count: 6))  // reserved
    Self.putU16BE(&mp4aP, 1)  // data_reference_index
    mp4aP.append(Data(count: 8))  // reserved
    Self.putU16BE(&mp4aP, channels)
    Self.putU16BE(&mp4aP, 16)  // samplesize
    Self.putU16BE(&mp4aP, 0)  // pre_defined
    Self.putU16BE(&mp4aP, 0)  // reserved
    Self.putU32BE(&mp4aP, sampleRate << 16)  // samplerate fixed 16.16
    mp4aP.append(esds)
    let mp4a = Self.mp4Box("mp4a", mp4aP)

    var stsdP = Data()
    Self.putU32BE(&stsdP, 1)
    stsdP.append(mp4a)
    let stsd = Self.mp4FullBox("stsd", payload: stsdP)

    let stbl = Self.mp4Box("stbl", stsd + Self.emptyStbl())
    let minf = Self.mp4Box("minf", smhd + dinf + stbl)
    let mdia = Self.mp4Box("mdia", mdhd + hdlr + minf)
    return Self.mp4Box("trak", tkhd + mdia)
  }

  // MARK: - MP4 Box Helpers

  private static func mp4Box(_ type: String, _ payload: Data) -> Data {
    let size = UInt32(payload.count + 8)
    var data = Data()
    putU32BE(&data, size)
    data.append(contentsOf: Array(type.utf8.prefix(4)))
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
    putU32BE(&data, 0x0001_0000); putU32BE(&data, 0); putU32BE(&data, 0)
    putU32BE(&data, 0); putU32BE(&data, 0x0001_0000); putU32BE(&data, 0)
    putU32BE(&data, 0); putU32BE(&data, 0); putU32BE(&data, 0x4000_0000)
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

  /// Build an ESDS box with a pre-computed AudioSpecificConfig (e.g., AAC-ELD).
  private static func buildEsds(trackID: UInt32, audioConfig: Data) -> Data {
    // DecoderSpecificInfo
    var dsi = Data([0x05, UInt8(audioConfig.count)])
    dsi.append(audioConfig)

    // DecoderConfigDescriptor
    var dcd = Data()
    dcd.append(0x40)  // objectTypeIndication: Audio ISO/IEC 14496-3
    dcd.append(0x15)  // streamType=audio | reserved
    dcd.append(contentsOf: [0x00, 0x00, 0x00])  // bufferSizeDB
    putU32BE(&dcd, 24000)  // maxBitrate
    putU32BE(&dcd, 24000)  // avgBitrate
    dcd.append(dsi)

    // ES_Descriptor
    var es = Data()
    putU16BE(&es, UInt16(trackID))  // ES_ID
    es.append(0x00)  // flags
    es.append(0x04)  // DecoderConfigDescriptor tag
    es.append(UInt8(dcd.count))
    es.append(dcd)
    es.append(contentsOf: [0x06, 0x01, 0x02])  // SLConfigDescriptor

    var desc = Data([0x03, UInt8(es.count)])
    desc.append(es)

    return mp4FullBox("esds", payload: desc)
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
