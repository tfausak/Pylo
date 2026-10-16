import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Locked
import SRTP
import Testing

@testable import Streaming

@Suite("Shared camera streaming")
struct SharedStreamTests {
  @Test(
    "Four encrypted viewers survive the original viewer closing, with matching or mixed settings",
    arguments: [false, true])
  func fourViewers(mixedSettings: Bool) throws {
    let hubVideo = try UDPSink()
    let hubAudio = try UDPSink()
    let unused = makeSession(index: 9, video: 0, audio: 0)
    let source = makeSession(index: 0, video: hubVideo.port, audio: hubAudio.port)
    var peers: [CameraStreamSession] = []
    var videoSinks: [UDPSink] = []
    var audioSinks: [UDPSink] = []
    defer {
      for peer in peers { peer.stopStreaming() }
      source.stopStreaming()
    }
    // Inject native camera frames into the same delivery path used by capture.
    // The inert source avoids opening a real camera or requesting permissions.
    try #require(start(source, sharing: unused))
    source.audioQueue.sync { source.setupAudioEncoder() }
    let recordedAudio = Locked(initialState: [Data]())
    source.onRecordingAudioFrame = { data in recordedAudio.withLock { $0.append(data) } }
    for index in 1...4 {
      let video = try UDPSink()
      let audio = try UDPSink()
      let peer = makeSession(index: index, video: video.port, audio: audio.port)
      peers.append(peer)
      videoSinks.append(video)
      audioSinks.append(audio)
      try #require(start(peer, sharing: source, smaller: mixedSettings && index == 4))
    }
    #expect(source.sharedViewers.value.count == 4)

    var buffer: CVPixelBuffer?
    try #require(
      CVPixelBufferCreate(
        nil, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == noErr)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
      let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
      memset(
        base, plane == 0 ? 80 : 128,
        CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
          * CVPixelBufferGetHeightOfPlane(pixels, plane))
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    source.captureQueue.sync { source.deliverVideoFrame(pixels, pts: .zero) }
    for index in peers.indices {
      let packet = try #require(videoSinks[index].mediaPacket(type: 99))
      let plain = try #require(context(for: peers[index]).unprotect(packet))
      #expect(plain[12] & 0x1F == 7)  // Fresh SPS at join.
      #expect(context(for: source).unprotect(packet) == nil)  // Different viewer keys.
      peers[index].rtpQueue.sync {}
      videoSinks[index].drain()
    }

    source.stopViewing()
    source.captureQueue.sync {
      source.deliverVideoFrame(pixels, pts: CMTime(value: 1, timescale: 1))
    }
    for index in peers.indices {
      let packet = try #require(videoSinks[index].mediaPacket(type: 99))
      #expect(context(for: peers[index]).unprotect(packet) != nil)
      peers[index].rtpQueue.sync {}
      videoSinks[index].drain()
    }
    peers[0].isMuted = true
    source.audioQueue.sync {
      for _ in 0..<3 { source.encodeAndSendAudioFrame(Data(count: 480 * 4)) }
    }
    let audio = try #require(recordedAudio.value.first)
    let expected = try #require(AUHeader.add(to: audio))
    for index in 1..<4 {
      let packet = try #require(audioSinks[index].mediaPacket(type: 110))
      let plain = try #require(context(for: peers[index]).unprotect(packet))
      #expect(Data(plain.dropFirst(12)) == expected)
    }
    peers[0].rtpQueue.sync {}
    #expect(audioSinks[0].mediaPacket(type: 110, timeout: 50) == nil)

    peers[0].stopStreaming()
    #expect(source.sharedViewers.value.count == 3)
    source.captureQueue.sync {
      source.deliverVideoFrame(pixels, pts: CMTime(value: 2, timescale: 1))
    }
    for index in 1..<4 {
      #expect(videoSinks[index].mediaPacket(type: 99) != nil)
    }
  }

  private func start(
    _ session: CameraStreamSession, sharing source: CameraStreamSession, smaller: Bool = false
  ) -> Bool {
    session.startStreaming(
      width: smaller ? 320 : 640, height: smaller ? 240 : 480,
      fps: smaller ? 15 : 30, bitrate: 1000, payloadType: 99,
      camera: nil, rotationAngle: 0, swapDimensions: false, microphoneEnabled: false,
      sharedSource: source)
  }

  private func makeSession(index: Int, video: UInt16, audio: UInt16) -> CameraStreamSession {
    CameraStreamSession(
      sessionID: Data(repeating: UInt8(index), count: 16),
      controllerAddress: "127.0.0.1", controllerVideoPort: video, controllerAudioPort: audio,
      videoSRTPKey: Data(repeating: UInt8(index), count: 16),
      videoSRTPSalt: Data(repeating: UInt8(index + 10), count: 14),
      audioSRTPKey: Data(repeating: UInt8(index), count: 16),
      audioSRTPSalt: Data(repeating: UInt8(index + 10), count: 14),
      localAddress: "127.0.0.1", localVideoPort: 0, localAudioPort: 0,
      videoSSRC: UInt32(index + 100), audioSSRC: UInt32(index + 200))
  }

  private func context(for session: CameraStreamSession) -> SRTPContext {
    SRTPContext(masterKey: session.videoSRTPKey, masterSalt: session.videoSRTPSalt)
  }
}

private final class UDPSink {
  let fd: Int32
  let port: UInt16

  init() throws {
    let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
    try #require(descriptor >= 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      close(descriptor)
      throw CocoaError(.fileReadUnknown)
    }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let queried = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &size)
      }
    }
    guard queried == 0 else {
      close(descriptor)
      throw CocoaError(.fileReadUnknown)
    }
    fd = descriptor
    port = UInt16(bigEndian: address.sin_port)
  }

  deinit { close(fd) }

  func mediaPacket(type: UInt8, timeout: Int32 = 2000) -> Data? {
    let deadline = Date.timeIntervalSinceReferenceDate + Double(timeout) / 1000
    var bytes = [UInt8](repeating: 0, count: 2048)
    repeat {
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let remaining = max(0, Int32((deadline - Date.timeIntervalSinceReferenceDate) * 1000))
      guard poll(&descriptor, 1, remaining) > 0 else { return nil }
      let count = recv(fd, &bytes, bytes.count, 0)
      if count > 12, bytes[1] & 0x7F == type { return Data(bytes.prefix(count)) }
    } while Date.timeIntervalSinceReferenceDate < deadline
    return nil
  }

  func drain() {
    var bytes = [UInt8](repeating: 0, count: 2048)
    while recv(fd, &bytes, bytes.count, MSG_DONTWAIT) > 0 {}
  }
}
