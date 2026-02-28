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

  /// The initialization segment (ftyp + moov) — manually constructed from the video
  /// format description since AVAssetWriter's fragmented mode produces a minimal moov
  /// without track descriptions or H.264 SPS/PPS codec parameters.
  private(set) var initSegment: Data?

  /// Video format description (contains H.264 SPS/PPS) captured from the first sample.
  private var videoFormatDescription: CMFormatDescription?
  /// Video track timescale from the source sample buffers.
  private var videoTimescale: UInt32 = 600

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
    // Capture video format description and eagerly build init segment
    // so it's available when the hub opens a recording channel.
    if videoFormatDescription == nil, let fmt = formatDescription {
      videoFormatDescription = fmt
      let ts = time.timescale
      if ts > 0 { videoTimescale = UInt32(ts) }
      initSegment = buildInitSegment(videoFormat: fmt)
    }

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

    // Strip ftyp+moov from fragment data — only keep moof+mdat segments
    var mediaData = extractMediaSegments(from: fragmentData)

    // Patch the moof's sequence_number — each AVAssetWriter instance starts at 1,
    // but the hub expects globally incrementing sequence numbers across fragments.
    Self.patchMoofSequenceNumber(&mediaData, sequenceNumber: UInt32(seq + 1))

    // Log first fragment's moof structure for diagnostics
    if seq == 0 {
      Self.logMoofInfo(mediaData, logger: logger)
    }
    let fragment = MP4Fragment(
      data: mediaData,
      timestamp: fragmentStartTime,
      duration: duration,
      sequenceNumber: seq
    )

    ringBuffer.append(fragment)
    onFragmentReady?(fragment)

    logger.debug(
      "Fragment #\(seq) complete: \(mediaData.count) bytes, \(String(format: "%.1f", CMTimeGetSeconds(duration)))s"
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

  // MARK: - Moof Patching

  /// Patch the mfhd.sequence_number inside a moof box.
  /// Each AVAssetWriter instance always starts at 1, but the hub expects
  /// globally incrementing sequence numbers (ISO 14496-12 §8.8.5).
  private static func patchMoofSequenceNumber(_ data: inout Data, sequenceNumber: UInt32) {
    guard let moofRange = findBoxRange(in: data, type: "moof") else { return }
    let moofContent = moofRange.lowerBound + 8
    guard let mfhdRange = findBoxRange(
      in: data, type: "mfhd",
      within: moofContent..<moofRange.upperBound
    ) else { return }
    // mfhd: [size:4][type:4][version:1][flags:3][sequence_number:4]
    let seqOffset = mfhdRange.lowerBound + 12
    guard seqOffset + 4 <= data.count else { return }
    data[seqOffset] = UInt8((sequenceNumber >> 24) & 0xFF)
    data[seqOffset + 1] = UInt8((sequenceNumber >> 16) & 0xFF)
    data[seqOffset + 2] = UInt8((sequenceNumber >> 8) & 0xFF)
    data[seqOffset + 3] = UInt8(sequenceNumber & 0xFF)
  }

  /// Find a top-level MP4 box of the given type within a data range.
  private static func findBoxRange(
    in data: Data, type: String, within range: Range<Int>? = nil
  ) -> Range<Int>? {
    let searchRange = range ?? 0..<data.count
    var offset = searchRange.lowerBound
    while offset + 8 <= searchRange.upperBound {
      let size =
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
        | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
      let boxType = String(bytes: data[offset + 4..<offset + 8], encoding: .ascii)
      guard size > 0 else { break }
      let boxEnd = offset + size
      if boxType == type {
        return offset..<min(boxEnd, searchRange.upperBound)
      }
      offset = boxEnd
    }
    return nil
  }

  /// Log diagnostic info about the first fragment's moof structure.
  private static func logMoofInfo(_ data: Data, logger: Logger) {
    guard let moofRange = findBoxRange(in: data, type: "moof") else {
      logger.warning("First fragment: no moof box found")
      return
    }
    let moofContent = moofRange.lowerBound + 8
    // Find traf(s) and their tfhd track IDs
    var searchStart = moofContent
    var trackInfo: [String] = []
    while let trafRange = findBoxRange(
      in: data, type: "traf", within: searchStart..<moofRange.upperBound
    ) {
      let trafContent = trafRange.lowerBound + 8
      if let tfhdRange = findBoxRange(
        in: data, type: "tfhd", within: trafContent..<trafRange.upperBound
      ) {
        let trackIDOffset = tfhdRange.lowerBound + 12
        if trackIDOffset + 4 <= data.count {
          let trackID =
            UInt32(data[trackIDOffset]) << 24
            | UInt32(data[trackIDOffset + 1]) << 16
            | UInt32(data[trackIDOffset + 2]) << 8
            | UInt32(data[trackIDOffset + 3])
          trackInfo.append("track=\(trackID)")
        }
      }
      if let tfdtRange = findBoxRange(
        in: data, type: "tfdt", within: trafContent..<trafRange.upperBound
      ) {
        let version = data[tfdtRange.lowerBound + 8]
        trackInfo.append("tfdt_v\(version)")
      }
      searchStart = trafRange.upperBound
    }
    logger.info("First fragment moof: \(trackInfo.joined(separator: ", "))")
  }

  // MARK: - Media Segment Extraction

  /// Extract media segments (moof + mdat) from a complete fMP4 file,
  /// skipping the ftyp and moov boxes at the beginning.
  private func extractMediaSegments(from data: Data) -> Data {
    var offset = 0
    while offset + 8 <= data.count {
      let size =
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
        | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
      let type = String(bytes: data[offset + 4..<offset + 8], encoding: .ascii)
      guard size > 0 else { break }
      if type == "moof" || type == "mdat" {
        return Data(data[offset...])
      }
      offset += size
    }
    return data
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

    logger.info(
      "buildInitSegment: \(width)x\(height), SPS=\(sps.count)B, PPS=\(pps.count)B, timescale=\(self.videoTimescale)"
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
    Self.putU32BE(&mvhdP, 3)  // next_track_ID
    let mvhd = Self.mp4FullBox("mvhd", payload: mvhdP)

    let videoTrack = buildVideoTrack(
      trackID: 1, width: width, height: height, sps: sps, pps: pps)
    let audioTrack = buildAudioTrack(trackID: 2)

    // mvex (movie extends — required for fragmented MP4)
    let mvex = Self.mp4Box("mvex", Self.buildTrex(trackID: 1) + Self.buildTrex(trackID: 2))

    let moov = Self.mp4Box("moov", mvhd + videoTrack + audioTrack + mvex)

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
    let sampleRate: UInt32 = 24000
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

    // stsd with mp4a
    let esds = Self.buildEsds(
      trackID: trackID, sampleRate: sampleRate, channels: channels)
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

  private static func buildEsds(
    trackID: UInt32, sampleRate: UInt32, channels: UInt16
  ) -> Data {
    // AudioSpecificConfig: objectType=2(AAC-LC), freqIndex, channelConfig
    let freqIndex: UInt8 = {
      switch sampleRate {
      case 96000: return 0; case 88200: return 1; case 64000: return 2
      case 48000: return 3; case 44100: return 4; case 32000: return 5
      case 24000: return 6; case 22050: return 7; case 16000: return 8
      case 12000: return 9; case 11025: return 10; case 8000: return 11
      default: return 6
      }
    }()
    let ch = UInt8(channels & 0x0F)
    let audioConfig = Data([
      UInt8((2 << 3) | Int(freqIndex >> 1)),
      UInt8(Int(freqIndex & 1) << 7 | Int(ch) << 3),
    ])

    // DecoderSpecificInfo
    var dsi = Data([0x05, UInt8(audioConfig.count)])
    dsi.append(audioConfig)

    // DecoderConfigDescriptor
    var dcd = Data()
    dcd.append(0x40)  // objectTypeIndication: Audio ISO/IEC 14496-3
    dcd.append(0x15)  // streamType=audio | reserved
    dcd.append(contentsOf: [0x00, 0x00, 0x00])  // bufferSizeDB
    putU32BE(&dcd, 64000)  // maxBitrate
    putU32BE(&dcd, 64000)  // avgBitrate
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
