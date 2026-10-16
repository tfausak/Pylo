import CoreMedia
import CoreVideo
import Foundation
import Locked
import Testing

@testable import Streaming

@Suite("Native 4K Recording Encoder")
struct VideoEncoderTests {
  @Test(
    "Hardware HEVC retains native 4K dimensions and rejects smaller input",
    arguments: [false, true])
  @available(iOS 17.4, *)
  func native4K(portrait: Bool) throws {
    let width = portrait ? 2160 : 3840
    let height = portrait ? 3840 : 2160
    let results = Locked(
      initialState: (
        count: 0, failures: [OSStatus](), dimensions: CMVideoDimensions(width: 0, height: 0),
        codec: CMVideoCodecType(0)
      ))
    let encoder = try VideoEncoder(portrait: portrait) { status, sample in
      let format = sample?.formatDescription
      let dimensions = format.map { CMVideoFormatDescriptionGetDimensions($0) }
      let codec = format.map { CMFormatDescriptionGetMediaSubType($0) }
      results.withLock { result in
        if status != noErr { result.failures.append(status) }
        if let dimensions, let codec {
          result.count += 1
          result.dimensions = dimensions
          result.codec = codec
        }
      }
    }
    var buffer: CVPixelBuffer?
    try #require(
      CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == noErr)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
      let pointer = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
      memset(
        pointer, plane == 0 ? 90 : 128,
        CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
          * CVPixelBufferGetHeightOfPlane(pixels, plane))
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    for frame in 0..<12 {
      try encoder.encode(pixels, pts: CMTime(value: Int64(frame), timescale: 30))
    }
    try encoder.finish()
    let result = results.value
    #expect(result.failures.isEmpty)
    #expect(result.count == 12)
    #expect(result.codec == kCMVideoCodecType_HEVC)
    #expect(result.dimensions.width == width)
    #expect(result.dimensions.height == height)
    var smaller: CVPixelBuffer?
    try #require(
      CVPixelBufferCreate(
        nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nil, &smaller) == noErr)
    let small = try #require(smaller)
    #expect(throws: VideoEncoder.Failure.invalidConfiguration) {
      try encoder.encode(small, pts: CMTime(value: 12, timescale: 30))
    }
  }
}
