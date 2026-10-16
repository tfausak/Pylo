import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Locked
import Testing
import VideoToolbox

@testable import FragmentedMP4

private typealias EncoderOutput = Locked<(buffers: [CMSampleBuffer], statuses: [OSStatus])>

@Suite("HEVC Recording")
struct HEVCRecordingTests {
  @Test("Producer reference time uses zero flags and big-endian NTP and media clocks")
  func producerReferenceTime() {
    let box = FragmentedMP4Writer.producerReferenceTimeBox(
      date: Date(timeIntervalSince1970: 0.5), mediaTime: 0x1234_5678_9ABC_DEF0)
    #expect(
      box
        == Data([
          0, 0, 0, 32, 0x70, 0x72, 0x66, 0x74, 1, 0, 0, 0,
          0, 0, 0, 1, 0x83, 0xAA, 0x7E, 0x80, 0x80, 0, 0, 0,
          0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        ]))
  }
  @Test("Real 4K HEVC frames survive MP4 packaging and decoding", arguments: [false, true])
  func roundTrip4K(portrait: Bool) async throws {
    let width = portrait ? 2160 : 3840
    let height = portrait ? 3840 : 2160
    let output = EncoderOutput(initialState: ([], []))
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
      encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: { refcon, _, status, _, buffer in
        guard let refcon else { return }
        Unmanaged<EncoderOutput>.fromOpaque(refcon).takeUnretainedValue().withLockUnchecked {
          $0.statuses.append(status)
          if let buffer { $0.buffers.append(buffer) }
        }
      },
      refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &session)
    try #require(status == noErr)
    let encoder = try #require(session)
    defer { VTCompressionSessionInvalidate(encoder) }
    try #require(
      VTSessionSetProperty(
        encoder, key: kVTCompressionPropertyKey_ProfileLevel,
        value: kVTProfileLevel_HEVC_Main_AutoLevel) == noErr)
    try #require(
      VTSessionSetProperty(
        encoder, key: kVTCompressionPropertyKey_AllowFrameReordering,
        value: kCFBooleanFalse) == noErr)

    var pixelBuffer: CVPixelBuffer?
    try #require(
      CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == noErr)
    let pixels = try #require(pixelBuffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
      let address = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
      memset(
        address, plane == 0 ? 80 : 128,
        CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
          * CVPixelBufferGetHeightOfPlane(pixels, plane))
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    for frame in 0..<3 {
      try #require(
        VTCompressionSessionEncodeFrame(
          encoder, imageBuffer: pixels,
          presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30),
          duration: CMTime(value: 1, timescale: 30), frameProperties: nil,
          sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr)
    }
    try #require(
      VTCompressionSessionCompleteFrames(
        encoder, untilPresentationTimeStamp: .positiveInfinity) == noErr)
    let (samples, errors) = output.valueUnchecked
    try #require(samples.count == 3)
    #expect(errors.allSatisfy { $0 == noErr })

    let writer = FragmentedMP4Writer()
    for sample in samples { writer.appendVideoSample(sample) }
    let initialization = try #require(writer.initSegment)
    #expect(initialization.range(of: Data("hvc1".utf8)) != nil)
    #expect(initialization.range(of: Data("hvcC".utf8)) != nil)
    #expect(initialization.range(of: Data("avcC".utf8)) == nil)
    writer.stop()
    let fragment = try #require(writer.ringBuffer.snapshot().first)
    #expect(fragment.data.subdata(in: 4..<8) == Data("prft".utf8))
    #expect(fragment.data.subdata(in: 8..<12) == Data([1, 0, 0, 0]))

    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("pylo-hevc-\(UUID()).mp4")
    defer { try? FileManager.default.removeItem(at: file) }
    try (initialization + fragment.data).write(to: file)
    let asset = AVURLAsset(url: file)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let decoded = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(decoded)
    try #require(reader.startReading())
    var frameCount = 0
    while let sample = decoded.copyNextSampleBuffer() {
      let pixels = try #require(sample.imageBuffer)
      #expect(CVPixelBufferGetWidth(pixels) == width)
      #expect(CVPixelBufferGetHeight(pixels) == height)
      frameCount += 1
    }
    #expect(frameCount == 3)
    #expect(reader.status == .completed)
  }
}
