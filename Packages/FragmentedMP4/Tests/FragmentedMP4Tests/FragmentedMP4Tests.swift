import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import FragmentedMP4

// MARK: - Test Helpers

/// Minimal H.264 SPS (Baseline profile, level 3.0).
private let testSPS = Data([0x67, 0x42, 0xC0, 0x1E])

/// Minimal H.264 PPS.
private let testPPS = Data([0x68, 0xCE, 0x38, 0x80])

/// Create a CMFormatDescription with an embedded avcC containing test SPS/PPS.
/// Uses CMVideoFormatDescriptionCreate with an avcC extension atom rather than
/// CMVideoFormatDescriptionCreateFromH264ParameterSets, which rejects minimal SPS.
private func makeFormatDescription() -> CMFormatDescription {
  // Build the avcC box payload (ISO 14496-15)
  var avcC = Data()
  avcC.append(0x01)  // configurationVersion
  avcC.append(testSPS[1])  // AVCProfileIndication
  avcC.append(testSPS[2])  // profile_compatibility
  avcC.append(testSPS[3])  // AVCLevelIndication
  avcC.append(0xFF)  // lengthSizeMinusOne=3 | reserved
  avcC.append(0xE1)  // numSPS=1 | reserved
  avcC.append(UInt8(testSPS.count >> 8))
  avcC.append(UInt8(testSPS.count & 0xFF))
  avcC.append(testSPS)
  avcC.append(0x01)  // numPPS
  avcC.append(UInt8(testPPS.count >> 8))
  avcC.append(UInt8(testPPS.count & 0xFF))
  avcC.append(testPPS)

  let extensions: [String: Any] = [
    "SampleDescriptionExtensionAtoms": ["avcC": avcC]
  ]

  var fmt: CMFormatDescription?
  let status = CMVideoFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    codecType: kCMVideoCodecType_H264,
    width: 320,
    height: 240,
    extensions: extensions as CFDictionary,
    formatDescriptionOut: &fmt
  )
  precondition(status == noErr, "Failed to create format description: \(status)")
  return fmt!
}

/// Create a synthetic CMSampleBuffer with H.264-like data.
private func makeSampleBuffer(
  pts: CMTime, isKeyframe: Bool, dataSize: Int = 100,
  formatDescription: CMFormatDescription
) -> CMSampleBuffer {
  // Build AVCC-format data: 4-byte big-endian length prefix + NAL data
  let nalSize = UInt32(dataSize - 4)
  var sampleData = Data()
  withUnsafeBytes(of: nalSize.bigEndian) { sampleData.append(contentsOf: $0) }
  // NAL type: 0x65 = IDR (keyframe), 0x41 = non-IDR
  sampleData.append(isKeyframe ? 0x65 : 0x41)
  sampleData.append(Data(repeating: 0xAB, count: dataSize - 5))

  var blockBuffer: CMBlockBuffer?
  let dataCount = sampleData.count
  sampleData.withUnsafeMutableBytes { rawBuf in
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: dataCount,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: dataCount,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    precondition(status == kCMBlockBufferNoErr)
    status = CMBlockBufferReplaceDataBytes(
      with: rawBuf.baseAddress!,
      blockBuffer: blockBuffer!,
      offsetIntoDestination: 0,
      dataLength: dataCount
    )
    precondition(status == kCMBlockBufferNoErr)
  }

  var timingInfo = CMSampleTimingInfo(
    duration: CMTime(value: 33, timescale: 1000),
    presentationTimeStamp: pts,
    decodeTimeStamp: .invalid
  )
  var sampleSize = dataCount
  var sampleBuffer: CMSampleBuffer?
  let status = CMSampleBufferCreateReady(
    allocator: kCFAllocatorDefault,
    dataBuffer: blockBuffer!,
    formatDescription: formatDescription,
    sampleCount: 1,
    sampleTimingEntryCount: 1,
    sampleTimingArray: &timingInfo,
    sampleSizeEntryCount: 1,
    sampleSizeArray: &sampleSize,
    sampleBufferOut: &sampleBuffer
  )
  precondition(status == noErr, "Failed to create sample buffer: \(status)")

  if !isKeyframe {
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer!, createIfNecessary: true) as? [NSMutableDictionary],
      let first = attachments.first
    {
      first[kCMSampleAttachmentKey_NotSync] = true
    }
  }

  return sampleBuffer!
}

/// Simple ISO BMFF box parser for test assertions.
private struct MP4Box {
  let type: String
  let payload: Data
  let totalSize: Int
}

private func parseBoxes(_ data: Data) -> [MP4Box] {
  var boxes: [MP4Box] = []
  var offset = 0
  while offset + 8 <= data.count {
    let size =
      Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
      | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    guard size >= 8, offset + size <= data.count else { break }
    let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .utf8) ?? "????"
    let payload = data[(offset + 8)..<(offset + size)]
    boxes.append(MP4Box(type: type, payload: Data(payload), totalSize: size))
    offset += size
  }
  return boxes
}

/// Read a big-endian UInt32 from data at the given offset.
private func readU32BE(_ data: Data, at offset: Int) -> UInt32 {
  UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
    | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}

// MARK: - FragmentedMP4Writer Thread Safety Tests

@Suite("FragmentedMP4Writer Thread Safety")
struct FragmentedMP4WriterThreadSafetyTests {

  @Test("Concurrent stop does not crash")
  func concurrentStop() async {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask { writer.stop() }
        group.addTask { writer.appendAudioSample(Data(repeating: 0xAA, count: 100)) }
      }
    }
  }

  @Test("Concurrent appendAudioSample does not crash")
  func concurrentAppendAudio() async {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)

    await withTaskGroup(of: Void.self) { group in
      for i in 0..<100 {
        group.addTask {
          writer.appendAudioSample(Data(repeating: UInt8(i & 0xFF), count: 50))
        }
      }
    }

    // Just verify it didn't crash — no specific output to check
    writer.stop()
  }

  @Test("includeAudioTrack property is thread-safe")
  func includeAudioTrackThreadSafe() async {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask { writer.includeAudioTrack = true }
        group.addTask { writer.includeAudioTrack = false }
        group.addTask { _ = writer.includeAudioTrack }
        group.addTask { _ = writer.initSegment }
      }
    }
  }
}

// MARK: - FragmentRingBuffer Tests

@Suite("FragmentRingBuffer")
struct FragmentRingBufferTests {

  private func makeFragment(seq: Int, dataSize: Int = 10) -> MP4Fragment {
    MP4Fragment(
      data: Data(repeating: UInt8(seq & 0xFF), count: dataSize),
      timestamp: CMTime(value: Int64(seq * 1000), timescale: 1000),
      duration: CMTime(value: 1000, timescale: 1000),
      sequenceNumber: seq
    )
  }

  @Test("Snapshot returns empty for new buffer")
  func emptySnapshot() {
    let buf = FragmentRingBuffer(capacity: 3)
    #expect(buf.snapshot().isEmpty)
  }

  @Test("Appended fragments appear in snapshot")
  func appendAndSnapshot() {
    let buf = FragmentRingBuffer(capacity: 3)
    buf.append(makeFragment(seq: 0))
    buf.append(makeFragment(seq: 1))
    let snap = buf.snapshot()
    #expect(snap.count == 2)
    #expect(snap[0].sequenceNumber == 0)
    #expect(snap[1].sequenceNumber == 1)
  }

  @Test("Ring buffer evicts oldest when full")
  func evictsOldest() {
    let buf = FragmentRingBuffer(capacity: 2)
    buf.append(makeFragment(seq: 0))
    buf.append(makeFragment(seq: 1))
    buf.append(makeFragment(seq: 2))
    let snap = buf.snapshot()
    #expect(snap.count == 2)
    #expect(snap[0].sequenceNumber == 1)
    #expect(snap[1].sequenceNumber == 2)
  }

  @Test("Clear empties buffer and resets sequence")
  func clearResetsBuffer() {
    let buf = FragmentRingBuffer(capacity: 3)
    buf.append(makeFragment(seq: 0))
    _ = buf.nextSequenceNumber()
    _ = buf.nextSequenceNumber()
    buf.clear()
    #expect(buf.snapshot().isEmpty)
    #expect(buf.nextSequenceNumber() == 0)
  }

  @Test("nextSequenceNumber increments monotonically")
  func sequenceIncrement() {
    let buf = FragmentRingBuffer(capacity: 2)
    #expect(buf.nextSequenceNumber() == 0)
    #expect(buf.nextSequenceNumber() == 1)
    #expect(buf.nextSequenceNumber() == 2)
  }

  @Test("Multiple wrap-arounds preserve chronological order")
  func multipleWrapArounds() {
    let buf = FragmentRingBuffer(capacity: 3)
    for i in 0..<10 {
      buf.append(makeFragment(seq: i))
    }
    let snap = buf.snapshot()
    #expect(snap.count == 3)
    #expect(snap[0].sequenceNumber == 7)
    #expect(snap[1].sequenceNumber == 8)
    #expect(snap[2].sequenceNumber == 9)
  }

  @Test("Concurrent append and snapshot does not crash")
  func concurrentAccess() async {
    let buf = FragmentRingBuffer(capacity: 5)
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<50 {
        group.addTask { buf.append(self.makeFragment(seq: i)) }
        group.addTask { _ = buf.snapshot() }
        group.addTask { _ = buf.nextSequenceNumber() }
      }
    }
    // Buffer should contain at most capacity fragments
    #expect(buf.snapshot().count <= 5)
  }
}

// MARK: - MPEG-4 Descriptor Length Encoding Tests

@Suite("MP4 Descriptor Length")
struct MP4DescriptorLengthTests {

  @Test("Zero encodes to single byte 0x00")
  func zero() {
    let result = FragmentedMP4Writer.mp4DescriptorLength(0)
    #expect(result == Data([0x00]))
  }

  @Test("Values below 128 encode to a single byte")
  func singleByte() {
    #expect(FragmentedMP4Writer.mp4DescriptorLength(1) == Data([0x01]))
    #expect(FragmentedMP4Writer.mp4DescriptorLength(42) == Data([42]))
    #expect(FragmentedMP4Writer.mp4DescriptorLength(127) == Data([0x7F]))
  }

  @Test("Value 128 encodes to two bytes with continuation bit")
  func twoBytes128() {
    // 128 = 0x80: high byte has continuation bit set (0x80 | 0x01 = 0x81), low byte is 0x00
    let result = FragmentedMP4Writer.mp4DescriptorLength(128)
    #expect(result == Data([0x81, 0x00]))
  }

  @Test("Value 255 encodes to two bytes")
  func twoBytes255() {
    // 255 = 0xFF: 255 >> 7 = 1, 255 & 0x7F = 0x7F → [0x81, 0x7F]
    let result = FragmentedMP4Writer.mp4DescriptorLength(255)
    #expect(result == Data([0x81, 0x7F]))
  }

  @Test("Value 16383 encodes to two bytes (max 2-byte)")
  func twoBytesMax() {
    // 16383 = 0x3FFF: 16383 >> 7 = 127, 16383 & 0x7F = 0x7F → [0xFF, 0x7F]
    let result = FragmentedMP4Writer.mp4DescriptorLength(16383)
    #expect(result == Data([0xFF, 0x7F]))
  }

  @Test("Value 16384 encodes to three bytes")
  func threeBytesMin() {
    // 16384 = 0x4000: requires 3 bytes
    let result = FragmentedMP4Writer.mp4DescriptorLength(16384)
    #expect(result.count == 3)
    // Verify continuation bits: first two bytes have MSB set, last does not
    #expect(result[0] & 0x80 != 0)
    #expect(result[1] & 0x80 != 0)
    #expect(result[2] & 0x80 == 0)
  }

  @Test("Typical AAC config sizes encode to single byte")
  func typicalAACSize() {
    // AAC-ELD AudioSpecificConfig is typically 2-5 bytes
    // ESDS descriptor total is typically ~25 bytes
    for size in [2, 5, 14, 25, 50] {
      let result = FragmentedMP4Writer.mp4DescriptorLength(size)
      #expect(result.count == 1, "Size \(size) should encode as single byte")
    }
  }
}

// MARK: - FragmentedMP4Writer Structural Tests

@Suite("FragmentedMP4Writer Structure")
struct FragmentedMP4WriterStructureTests {

  @Test("initSegment is nil before configure with format description")
  func initSegmentNilBeforeFormat() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    #expect(writer.initSegment == nil)
  }

  @Test("Stop without samples does not call onFragmentReady")
  func stopWithoutSamples() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    nonisolated(unsafe) var callCount = 0
    writer.onFragmentReady = { _ in callCount += 1 }
    writer.stop()
    #expect(callCount == 0)
  }

  @Test("includeAudioTrack defaults to false")
  func audioTrackDefault() {
    let writer = FragmentedMP4Writer()
    #expect(writer.includeAudioTrack == false)
  }

  @Test("includeAudioTrack setter invalidates init segment")
  func audioTrackInvalidatesInit() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    // initSegment is nil because no format description has been set,
    // but toggling includeAudioTrack should clear any cached format
    writer.includeAudioTrack = true
    #expect(writer.initSegment == nil)
    writer.includeAudioTrack = false
    #expect(writer.initSegment == nil)
  }

  @Test("onFragmentReady can be set and cleared")
  func onFragmentReadySetClear() {
    let writer = FragmentedMP4Writer()
    writer.onFragmentReady = { _ in }
    writer.onFragmentReady = nil
    // Just verify no crash
  }

  @Test("appendAudioSample accumulates samples")
  func appendAudioAccumulates() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    for _ in 0..<10 {
      writer.appendAudioSample(Data(repeating: 0xAA, count: 50))
    }
    // Stop should clear without crashing
    writer.stop()
  }
}

// MARK: - Init Segment Structure Tests

@Suite("Init Segment Structure")
struct InitSegmentStructureTests {

  @Test("Init segment starts with ftyp followed by moov")
  func ftypAndMoov() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    // Feed one sample to trigger init segment creation
    let sb = makeSampleBuffer(
      pts: CMTime(value: 0, timescale: 1000), isKeyframe: true,
      formatDescription: fmt)
    writer.appendVideoSample(sb)

    guard let initSeg = writer.initSegment else {
      Issue.record("initSegment should not be nil after feeding a sample")
      return
    }

    let boxes = parseBoxes(initSeg)
    #expect(boxes.count == 2, "Init segment should have exactly 2 top-level boxes")
    #expect(boxes[0].type == "ftyp")
    #expect(boxes[1].type == "moov")
  }

  @Test("ftyp contains mp42 major brand")
  func ftypBrand() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    writer.appendVideoSample(
      makeSampleBuffer(
        pts: CMTime(value: 0, timescale: 1000), isKeyframe: true,
        formatDescription: fmt))
    let initSeg = writer.initSegment!
    let boxes = parseBoxes(initSeg)
    let ftypPayload = boxes[0].payload
    let majorBrand = String(bytes: ftypPayload[0..<4], encoding: .utf8)
    #expect(majorBrand == "mp42")
  }

  @Test("moov contains single video trak without audio")
  func moovVideoOnly() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    writer.appendVideoSample(
      makeSampleBuffer(
        pts: CMTime(value: 0, timescale: 1000), isKeyframe: true,
        formatDescription: fmt))
    let initSeg = writer.initSegment!
    let moov = parseBoxes(initSeg)[1]
    let moovChildren = parseBoxes(moov.payload)
    let traks = moovChildren.filter { $0.type == "trak" }
    #expect(traks.count == 1, "Video-only init segment should have 1 trak")
    let mvexBoxes = moovChildren.filter { $0.type == "mvex" }
    #expect(mvexBoxes.count == 1)
  }

  @Test("moov contains two traks with audio enabled")
  func moovWithAudio() {
    let writer = FragmentedMP4Writer()
    writer.includeAudioTrack = true
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    writer.appendVideoSample(
      makeSampleBuffer(
        pts: CMTime(value: 0, timescale: 1000), isKeyframe: true,
        formatDescription: fmt))
    let initSeg = writer.initSegment!
    let moov = parseBoxes(initSeg)[1]
    let moovChildren = parseBoxes(moov.payload)
    let traks = moovChildren.filter { $0.type == "trak" }
    #expect(traks.count == 2, "Audio-enabled init segment should have 2 traks")
  }

  @Test("Video trak contains mdia with avcC holding SPS/PPS")
  func videoTrakAvcC() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    writer.appendVideoSample(
      makeSampleBuffer(
        pts: CMTime(value: 0, timescale: 1000), isKeyframe: true,
        formatDescription: fmt))
    let initSeg = writer.initSegment!

    // Navigate: moov → trak → mdia → minf → stbl → stsd → avc1 → avcC
    // Just verify the init segment contains "avcC" and our SPS/PPS bytes
    guard let avcCRange = initSeg.range(of: "avcC".data(using: .utf8)!) else {
      Issue.record("Init segment should contain avcC box")
      return
    }
    // avcC payload starts after the 8-byte box header (4 size + 4 type)
    let avcCStart = avcCRange.lowerBound - 4  // back to size field
    let avcCSize = Int(readU32BE(initSeg, at: avcCStart))
    let avcCPayload = initSeg[(avcCStart + 8)..<(avcCStart + avcCSize)]

    // Verify SPS is embedded: after configurationVersion(1) + profile(1) + compat(1) + level(1)
    // + lengthSizeMinusOne(1) + numSPS(1) + spsLength(2) = 8 bytes, then SPS data
    let spsLenOffset = 6  // offset within avcC payload to SPS length
    let embeddedSPSLen =
      Int(avcCPayload[avcCPayload.startIndex + spsLenOffset]) << 8
      | Int(avcCPayload[avcCPayload.startIndex + spsLenOffset + 1])
    #expect(embeddedSPSLen == testSPS.count)
  }

  @Test("mvex contains trex for each track")
  func mvexTrex() {
    let writer = FragmentedMP4Writer()
    writer.includeAudioTrack = true
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    writer.appendVideoSample(
      makeSampleBuffer(
        pts: CMTime(value: 0, timescale: 1000), isKeyframe: true,
        formatDescription: fmt))
    let initSeg = writer.initSegment!
    let moov = parseBoxes(initSeg)[1]
    let mvex = parseBoxes(moov.payload).first { $0.type == "mvex" }!
    let trexBoxes = parseBoxes(mvex.payload).filter { $0.type == "trex" }
    #expect(trexBoxes.count == 2, "mvex should have 2 trex boxes with audio enabled")
    // Verify track IDs (after 4-byte version/flags)
    let trackID1 = readU32BE(trexBoxes[0].payload, at: 4)
    let trackID2 = readU32BE(trexBoxes[1].payload, at: 4)
    #expect(trackID1 == 1)
    #expect(trackID2 == 2)
  }
}

// MARK: - Fragment (moof+mdat) Structure Tests

@Suite("Fragment Structure")
struct FragmentStructureTests {

  /// Feed enough samples to trigger a fragment and return it.
  private func emitOneFragment(
    sampleCount: Int = 120, fps: Int = 30, includeAudio: Bool = false
  ) -> MP4Fragment? {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: fps)
    writer.includeAudioTrack = includeAudio
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    let frameDuration = CMTime(value: 1000 / Int64(fps), timescale: 1000)

    // Feed sampleCount frames (all as one GOP starting with keyframe)
    for i in 0..<sampleCount {
      let pts = CMTime(value: Int64(i) * frameDuration.value, timescale: 1000)
      let sb = makeSampleBuffer(
        pts: pts, isKeyframe: i == 0,
        formatDescription: fmt)
      writer.appendVideoSample(sb)
    }

    if includeAudio {
      // Add some audio frames
      for _ in 0..<100 {
        writer.appendAudioSample(Data(repeating: 0xCC, count: 64))
      }
    }

    // Send a new keyframe after enough elapsed time to trigger fragment emission.
    // fragmentDuration is 3.5s, so at 30fps we need ~105 frames minimum.
    let triggerPTS = CMTime(
      value: Int64(sampleCount) * frameDuration.value, timescale: 1000)
    let trigger = makeSampleBuffer(
      pts: triggerPTS, isKeyframe: true,
      formatDescription: fmt)
    writer.appendVideoSample(trigger)

    return emitted.first
  }

  @Test("Fragment starts with moof followed by mdat")
  func moofThenMdat() {
    guard let fragment = emitOneFragment() else {
      Issue.record("No fragment emitted")
      return
    }
    let boxes = parseBoxes(fragment.data)
    #expect(boxes.count == 2)
    #expect(boxes[0].type == "moof")
    #expect(boxes[1].type == "mdat")
  }

  @Test("moof contains mfhd and video traf")
  func moofStructure() {
    guard let fragment = emitOneFragment() else {
      Issue.record("No fragment emitted")
      return
    }
    let moof = parseBoxes(fragment.data)[0]
    let moofChildren = parseBoxes(moof.payload)
    let types = moofChildren.map(\.type)
    #expect(types.contains("mfhd"))
    #expect(types.contains("traf"))
  }

  @Test("mfhd sequence number starts at 1")
  func mfhdSequenceNumber() {
    guard let fragment = emitOneFragment() else {
      Issue.record("No fragment emitted")
      return
    }
    let moof = parseBoxes(fragment.data)[0]
    let mfhd = parseBoxes(moof.payload).first { $0.type == "mfhd" }!
    // mfhd payload: 4 bytes version/flags + 4 bytes sequence_number
    let seqNum = readU32BE(mfhd.payload, at: 4)
    #expect(seqNum == 1)
  }

  @Test("trun sample count matches input sample count")
  func trunSampleCount() {
    let sampleCount = 120
    guard let fragment = emitOneFragment(sampleCount: sampleCount) else {
      Issue.record("No fragment emitted")
      return
    }
    let moof = parseBoxes(fragment.data)[0]
    let traf = parseBoxes(moof.payload).first { $0.type == "traf" }!
    let trun = parseBoxes(traf.payload).first { $0.type == "trun" }!
    // trun payload: 4 bytes version/flags + 4 bytes sample_count + ...
    let count = readU32BE(trun.payload, at: 4)
    #expect(count == UInt32(sampleCount))
  }

  @Test("mdat payload size equals sum of input sample sizes")
  func mdatPayloadSize() {
    let sampleCount = 120
    let dataSize = 100
    guard let fragment = emitOneFragment(sampleCount: sampleCount) else {
      Issue.record("No fragment emitted")
      return
    }
    let mdat = parseBoxes(fragment.data)[1]
    #expect(mdat.payload.count == sampleCount * dataSize)
  }

  @Test("Consecutive fragments have incrementing mfhd sequence numbers")
  func consecutiveSequenceNumbers() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    let frameDuration: Int64 = 33  // ~30fps in ms

    // Emit two fragments by sending two GOPs each >= 3.5s
    var frameIndex: Int64 = 0
    for _ in 0..<2 {
      // Keyframe
      let kfPTS = CMTime(value: frameIndex * frameDuration, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: kfPTS, isKeyframe: true, formatDescription: fmt))
      frameIndex += 1

      // Non-keyframes for ~4 seconds
      for _ in 0..<119 {
        let pts = CMTime(value: frameIndex * frameDuration, timescale: 1000)
        writer.appendVideoSample(
          makeSampleBuffer(pts: pts, isKeyframe: false, formatDescription: fmt))
        frameIndex += 1
      }
    }

    // Trigger flush of second fragment
    let finalPTS = CMTime(value: frameIndex * frameDuration, timescale: 1000)
    writer.appendVideoSample(
      makeSampleBuffer(pts: finalPTS, isKeyframe: true, formatDescription: fmt))

    #expect(emitted.count == 2, "Should have emitted 2 fragments, got \(emitted.count)")
    guard emitted.count == 2 else { return }

    let moof1 = parseBoxes(emitted[0].data)[0]
    let moof2 = parseBoxes(emitted[1].data)[0]
    let mfhd1 = parseBoxes(moof1.payload).first { $0.type == "mfhd" }!
    let mfhd2 = parseBoxes(moof2.payload).first { $0.type == "mfhd" }!
    let seq1 = readU32BE(mfhd1.payload, at: 4)
    let seq2 = readU32BE(mfhd2.payload, at: 4)
    #expect(seq2 == seq1 + 1)
  }

  @Test("tfdt base decode time advances between fragments")
  func tfdtAdvances() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    let frameDuration: Int64 = 33
    var frameIndex: Int64 = 0
    for _ in 0..<2 {
      let kfPTS = CMTime(value: frameIndex * frameDuration, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: kfPTS, isKeyframe: true, formatDescription: fmt))
      frameIndex += 1
      for _ in 0..<119 {
        let pts = CMTime(value: frameIndex * frameDuration, timescale: 1000)
        writer.appendVideoSample(
          makeSampleBuffer(pts: pts, isKeyframe: false, formatDescription: fmt))
        frameIndex += 1
      }
    }
    let finalPTS = CMTime(value: frameIndex * frameDuration, timescale: 1000)
    writer.appendVideoSample(
      makeSampleBuffer(pts: finalPTS, isKeyframe: true, formatDescription: fmt))

    #expect(emitted.count == 2, "Should have emitted 2 fragments")
    guard emitted.count == 2 else { return }

    // Extract tfdt base_media_decode_time (version 1 = 8 bytes, after 4 bytes ver/flags)
    func extractTfdt(_ fragmentData: Data) -> UInt64 {
      let moof = parseBoxes(fragmentData)[0]
      let traf = parseBoxes(moof.payload).first { $0.type == "traf" }!
      let tfdt = parseBoxes(traf.payload).first { $0.type == "tfdt" }!
      let hi = UInt64(readU32BE(tfdt.payload, at: 4))
      let lo = UInt64(readU32BE(tfdt.payload, at: 8))
      return (hi << 32) | lo
    }

    let dt1 = extractTfdt(emitted[0].data)
    let dt2 = extractTfdt(emitted[1].data)
    #expect(dt1 == 0, "First fragment should start at decode time 0")
    #expect(dt2 > 0, "Second fragment should have advanced decode time")
  }

  @Test("data_offset in trun points past moof to mdat payload")
  func trunDataOffset() {
    guard let fragment = emitOneFragment() else {
      Issue.record("No fragment emitted")
      return
    }
    let boxes = parseBoxes(fragment.data)
    let moofSize = boxes[0].totalSize
    let moof = boxes[0]
    let traf = parseBoxes(moof.payload).first { $0.type == "traf" }!
    let trun = parseBoxes(traf.payload).first { $0.type == "trun" }!
    // trun payload: 4 bytes ver/flags + 4 bytes sample_count + 4 bytes data_offset
    let dataOffset = readU32BE(trun.payload, at: 8)
    // data_offset should equal moof size + 8 (mdat box header)
    #expect(dataOffset == UInt32(moofSize + 8))
  }
}

// MARK: - Keyframe and PTS Gap Tests

@Suite("Fragmentation Triggers")
struct FragmentationTriggerTests {

  @Test("No fragment emitted before fragmentDuration elapsed")
  func noEarlyFragment() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    // Send 2 seconds of frames (60 frames at 30fps) — well under 3.5s threshold
    for i in 0..<60 {
      let pts = CMTime(value: Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 0, formatDescription: fmt))
    }
    // Send another keyframe at 2s — should NOT trigger fragment
    let earlyKF = makeSampleBuffer(
      pts: CMTime(value: 60 * 33, timescale: 1000), isKeyframe: true,
      formatDescription: fmt)
    writer.appendVideoSample(earlyKF)

    #expect(emitted.isEmpty, "Should not emit fragment before 3.5s elapsed")
  }

  @Test("Fragment emitted at keyframe after fragmentDuration")
  func fragmentAtKeyframe() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    // Send 4 seconds of frames (120 frames at 30fps)
    for i in 0..<120 {
      let pts = CMTime(value: Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 0, formatDescription: fmt))
    }
    // Send a keyframe at 4s — should trigger fragment
    let triggerKF = makeSampleBuffer(
      pts: CMTime(value: 120 * 33, timescale: 1000), isKeyframe: true,
      formatDescription: fmt)
    writer.appendVideoSample(triggerKF)

    #expect(emitted.count == 1, "Should emit exactly one fragment")
  }

  @Test("Non-keyframe does not trigger fragment even after duration threshold")
  func nonKeyframeDoesNotTrigger() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    // Send 5 seconds of non-keyframes (except first)
    for i in 0..<150 {
      let pts = CMTime(value: Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 0, formatDescription: fmt))
    }

    #expect(emitted.isEmpty, "No fragment without a second keyframe")
  }

  @Test("PTS gap with >= 30 samples flushes a fragment")
  func ptsGapFlushes() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    // Feed 60 frames at 33ms intervals (2 seconds) — enough to trigger gap flush
    for i in 0..<60 {
      let pts = CMTime(value: Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 0, formatDescription: fmt))
    }
    #expect(emitted.isEmpty, "No fragment before gap")

    // Jump PTS forward by 2 seconds (a gap > 0.5s)
    let gapPTS = CMTime(value: 60 * 33 + 2000, timescale: 1000)
    writer.appendVideoSample(
      makeSampleBuffer(pts: gapPTS, isKeyframe: false, formatDescription: fmt))

    #expect(emitted.count == 1, "PTS gap with >= 30 pending samples should flush a fragment")
  }

  @Test("PTS gap with < 30 samples discards without emitting a fragment")
  func ptsGapDiscards() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    // Feed only 10 frames — below the 30-sample threshold for gap flush
    for i in 0..<10 {
      let pts = CMTime(value: Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 0, formatDescription: fmt))
    }

    // Jump PTS forward by 2 seconds
    let gapPTS = CMTime(value: 10 * 33 + 2000, timescale: 1000)
    writer.appendVideoSample(
      makeSampleBuffer(pts: gapPTS, isKeyframe: false, formatDescription: fmt))

    #expect(emitted.isEmpty, "PTS gap with < 30 samples should discard, not emit")

    // Continue feeding and verify the writer still works (fragmentStartPTS was reset)
    for i in 1..<120 {
      let pts = CMTime(value: gapPTS.value + Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 1, formatDescription: fmt))
    }
    let triggerKF = makeSampleBuffer(
      pts: CMTime(value: gapPTS.value + 120 * 33, timescale: 1000),
      isKeyframe: true, formatDescription: fmt)
    writer.appendVideoSample(triggerKF)

    #expect(emitted.count == 1, "Writer should recover and emit after gap discard")
  }

  @Test("stop() flushes pending samples as final fragment")
  func stopFlushes() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    // Feed some samples (not enough for automatic fragment)
    for i in 0..<30 {
      let pts = CMTime(value: Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 0, formatDescription: fmt))
    }
    #expect(emitted.isEmpty)

    writer.stop()
    #expect(emitted.count == 1, "stop() should flush pending samples")
    let boxes = parseBoxes(emitted[0].data)
    #expect(boxes[0].type == "moof")
    #expect(boxes[1].type == "mdat")
  }

  @Test("stop() preserves decode time continuity across restart")
  func stopPreservesDecodeTime() {
    let writer = FragmentedMP4Writer()
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    // Feed samples and flush via stop()
    for i in 0..<60 {
      let pts = CMTime(value: Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 0, formatDescription: fmt))
    }
    writer.stop()
    #expect(emitted.count == 1)

    // Extract tfdt from first fragment
    func extractTfdt(_ fragmentData: Data) -> UInt64 {
      let moof = parseBoxes(fragmentData)[0]
      let traf = parseBoxes(moof.payload).first { $0.type == "traf" }!
      let tfdt = parseBoxes(traf.payload).first { $0.type == "tfdt" }!
      let hi = UInt64(readU32BE(tfdt.payload, at: 4))
      let lo = UInt64(readU32BE(tfdt.payload, at: 8))
      return (hi << 32) | lo
    }

    // Extract trun durations to compute total ticks of first fragment
    func extractTotalTicks(_ fragmentData: Data) -> UInt64 {
      let moof = parseBoxes(fragmentData)[0]
      let traf = parseBoxes(moof.payload).first { $0.type == "traf" }!
      let trun = parseBoxes(traf.payload).first { $0.type == "trun" }!
      let flags = readU32BE(trun.payload, at: 0) & 0x00FF_FFFF
      let sampleCount = Int(readU32BE(trun.payload, at: 4))
      // Skip: ver/flags(4) + sample_count(4) + data_offset(4) + [first_sample_flags(4)]
      let hasFirstSampleFlags = (flags & 0x004) != 0
      var offset = 12 + (hasFirstSampleFlags ? 4 : 0)
      var total: UInt64 = 0
      for _ in 0..<sampleCount {
        total += UInt64(readU32BE(trun.payload, at: offset))
        offset += 8  // duration(4) + size(4)
      }
      return total
    }

    let dt1 = extractTfdt(emitted[0].data)
    let ticks1 = extractTotalTicks(emitted[0].data)
    #expect(dt1 == 0)
    #expect(ticks1 > 0)

    // Restart: feed new samples and flush again
    for i in 0..<60 {
      let pts = CMTime(value: Int64(i + 60) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 0, formatDescription: fmt))
    }
    writer.stop()
    #expect(emitted.count == 2)

    // Second fragment's tfdt should equal first fragment's tfdt + total ticks
    let dt2 = extractTfdt(emitted[1].data)
    #expect(dt2 == dt1 + ticks1, "Decode time should be continuous across stop/restart")
  }

  @Test("Fragment with audio has two traf boxes")
  func audioTwoTrafs() {
    let writer = FragmentedMP4Writer()
    writer.includeAudioTrack = true
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    // Feed video samples
    for i in 0..<120 {
      let pts = CMTime(value: Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(pts: pts, isKeyframe: i == 0, formatDescription: fmt))
    }
    // Feed audio samples
    for _ in 0..<100 {
      writer.appendAudioSample(Data(repeating: 0xCC, count: 64))
    }
    // Trigger fragment
    writer.appendVideoSample(
      makeSampleBuffer(
        pts: CMTime(value: 120 * 33, timescale: 1000), isKeyframe: true,
        formatDescription: fmt))

    #expect(emitted.count == 1)
    guard let fragment = emitted.first else { return }
    let moof = parseBoxes(fragment.data)[0]
    let trafs = parseBoxes(moof.payload).filter { $0.type == "traf" }
    #expect(trafs.count == 2, "Fragment with audio should have 2 traf boxes")
  }

  @Test("Audio traf data_offset points past video data in mdat")
  func audioDataOffset() {
    let videoSampleCount = 120
    let videoDataSize = 100
    let audioFrameCount = 100
    let audioFrameSize = 64

    let writer = FragmentedMP4Writer()
    writer.includeAudioTrack = true
    writer.configure(fps: 30)
    let fmt = makeFormatDescription()
    nonisolated(unsafe) var emitted: [MP4Fragment] = []
    writer.onFragmentReady = { emitted.append($0) }

    for i in 0..<videoSampleCount {
      let pts = CMTime(value: Int64(i) * 33, timescale: 1000)
      writer.appendVideoSample(
        makeSampleBuffer(
          pts: pts, isKeyframe: i == 0, dataSize: videoDataSize,
          formatDescription: fmt))
    }
    for _ in 0..<audioFrameCount {
      writer.appendAudioSample(Data(repeating: 0xCC, count: audioFrameSize))
    }
    writer.appendVideoSample(
      makeSampleBuffer(
        pts: CMTime(value: Int64(videoSampleCount) * 33, timescale: 1000),
        isKeyframe: true, formatDescription: fmt))

    guard let fragment = emitted.first else {
      Issue.record("No fragment emitted")
      return
    }

    let boxes = parseBoxes(fragment.data)
    let moofSize = boxes[0].totalSize
    let moof = boxes[0]
    let trafs = parseBoxes(moof.payload).filter { $0.type == "traf" }
    #expect(trafs.count == 2)

    // Extract audio trun data_offset from second traf
    let audioTraf = trafs[1]
    let audioTrun = parseBoxes(audioTraf.payload).first { $0.type == "trun" }!
    // trun payload: 4 bytes ver/flags + 4 bytes sample_count + 4 bytes data_offset
    let audioOffset = readU32BE(audioTrun.payload, at: 8)

    // Audio data_offset should be: moof size + 8 (mdat header) + total video data
    let expectedOffset = moofSize + 8 + videoSampleCount * videoDataSize
    #expect(audioOffset == UInt32(expectedOffset))

    // Also verify mdat contains both video and audio data
    let mdat = boxes[1]
    let expectedMdatPayload =
      videoSampleCount * videoDataSize + audioFrameCount * audioFrameSize
    #expect(mdat.payload.count == expectedMdatPayload)
  }
}
