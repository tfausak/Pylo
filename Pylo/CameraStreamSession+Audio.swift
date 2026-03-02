@preconcurrency import AVFoundation
import AudioToolbox
@preconcurrency import CoreMedia
import Foundation
import SRTP
import os

// MARK: - Audio

extension CameraStreamSession {

  // MARK: - Audio Encoder (PCM → AAC-ELD)

  nonisolated func setupAudioEncoder() {
    // Input: Linear PCM Float32, 16kHz, mono
    var inputDesc = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    // Output: AAC-ELD, 16kHz, mono
    var outputDesc = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatMPEG4AAC_ELD,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: 480,
      mBytesPerFrame: 0,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 0,
      mReserved: 0
    )

    var converter: AudioConverterRef?
    let status = AudioConverterNew(&inputDesc, &outputDesc, &converter)
    guard status == noErr, let converter else {
      logger.error("AudioConverter (encoder) create failed: \(status)")
      return
    }

    // Set bitrate to 24kbps (good quality for voice)
    var bitrate: UInt32 = 24000
    AudioConverterSetProperty(
      converter, kAudioConverterEncodeBitRate,
      UInt32(MemoryLayout<UInt32>.size), &bitrate)

    self.audioConverter = converter
    logger.info("AAC-ELD encoder created (16kHz mono → AAC-ELD)")
  }

  // MARK: - Audio Sample Buffer Processing

  nonisolated func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    dispatchPrecondition(condition: .onQueue(captureQueue))
    guard audioConverter != nil else { return }
    guard audioSocketFD >= 0 else { return }
    guard !isMuted else { return }
    audioSampleCount += 1

    // Get PCM data from the sample buffer
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(
      blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard let ptr = dataPointer, totalLength > 0 else { return }

    // Get the source format to know what we're dealing with
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee

    let rawData = Data(bytes: ptr, count: totalLength)

    // Convert to Float32 at 16kHz if needed (the mic may deliver Int16 at 44.1/48kHz)
    let pcmFloat32: Data
    if let asbd, asbd.mFormatID == kAudioFormatLinearPCM {
      pcmFloat32 = convertToFloat32At16kHz(rawData, sourceASBD: asbd)
    } else {
      logger.warning("Audio: unexpected format ID \(asbd?.mFormatID ?? 0)")
      return
    }

    // Accumulate PCM and encode when we have enough for an AAC-ELD frame
    pcmAccumulator.append(pcmFloat32)
    let frameSizeBytes = aacFrameSamples * 4  // 480 samples * 4 bytes/sample (Float32)

    // Consume complete frames, deferring the single Data shift to after the loop
    // to avoid O(n) removeFirst per frame.
    var offset = pcmAccumulator.startIndex
    while offset + frameSizeBytes <= pcmAccumulator.endIndex {
      let frameData = Data(pcmAccumulator[offset..<offset + frameSizeBytes])
      offset += frameSizeBytes
      encodeAndSendAudioFrame(frameData)
    }
    if offset > pcmAccumulator.startIndex {
      pcmAccumulator.removeFirst(offset - pcmAccumulator.startIndex)
    }
  }

  /// Convert PCM audio data to Float32 at 16kHz mono.
  private nonisolated func convertToFloat32At16kHz(
    _ data: Data, sourceASBD: AudioStreamBasicDescription
  ) -> Data {
    let sourceSampleRate = sourceASBD.mSampleRate
    let sourceChannels = Int(sourceASBD.mChannelsPerFrame)
    let isFloat = (sourceASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let is16Bit = sourceASBD.mBitsPerChannel == 16

    // First convert to Float32 mono
    var floatSamples: [Float] = []

    if isFloat && sourceASBD.mBitsPerChannel == 32 {
      // Already Float32
      data.withUnsafeBytes { ptr in
        let floatPtr = ptr.bindMemory(to: Float.self)
        if sourceChannels == 1 {
          floatSamples = Array(floatPtr)
        } else {
          // Mix down to mono by averaging all channels
          for i in stride(from: 0, to: floatPtr.count, by: sourceChannels) {
            var sum: Float = 0
            for ch in 0..<sourceChannels where i + ch < floatPtr.count {
              sum += floatPtr[i + ch]
            }
            floatSamples.append(sum / Float(sourceChannels))
          }
        }
      }
    } else if is16Bit {
      // Int16 → Float32, mix down to mono if multi-channel
      data.withUnsafeBytes { ptr in
        let int16Ptr = ptr.bindMemory(to: Int16.self)
        for i in stride(from: 0, to: int16Ptr.count, by: sourceChannels) {
          var sum: Float = 0
          for ch in 0..<sourceChannels where i + ch < int16Ptr.count {
            sum += Float(int16Ptr[i + ch]) / 32768.0
          }
          floatSamples.append(sum / Float(sourceChannels))
        }
      }
    } else {
      logger.warning(
        "Unsupported audio format: \(sourceASBD.mBitsPerChannel)-bit, float=\(isFloat)")
      return Data()
    }

    // Resample to 16kHz if needed
    if abs(sourceSampleRate - 16000) > 1 {
      let ratio = 16000.0 / sourceSampleRate
      let outputCount = Int(Double(floatSamples.count) * ratio)
      var resampled = [Float](repeating: 0, count: outputCount)
      for i in 0..<outputCount {
        let srcIdx = Double(i) / ratio
        let idx = Int(srcIdx)
        let frac = Float(srcIdx - Double(idx))
        if idx + 1 < floatSamples.count {
          resampled[i] = floatSamples[idx] * (1 - frac) + floatSamples[idx + 1] * frac
        } else if idx < floatSamples.count {
          resampled[i] = floatSamples[idx]
        }
      }
      floatSamples = resampled
    }

    return floatSamples.withUnsafeBytes { Data($0) }
  }

  /// Encode a single AAC-ELD frame (480 samples) and send as an RTP packet.
  private nonisolated func encodeAndSendAudioFrame(_ pcmData: Data) {
    guard let converter = audioConverter else { return }

    let outputBufferSize = 1024
    let aacData: Data? = withUnsafeTemporaryAllocation(
      byteCount: outputBufferSize, alignment: 1
    ) { outputBuf -> Data? in
      var packetSize: UInt32 = 1

      var outputBufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 1,
          mDataByteSize: UInt32(outputBufferSize),
          mData: outputBuf.baseAddress
        )
      )

      var outputPacketDesc = AudioStreamPacketDescription()

      let status: OSStatus = pcmData.withUnsafeBytes { pcmBuf -> OSStatus in
        guard let pcmBase = pcmBuf.baseAddress else { return -1 }

        var cbData = AudioEncoderInput(
          srcData: pcmBase,
          srcSize: UInt32(pcmData.count),
          consumed: false
        )

        return withUnsafeMutablePointer(to: &cbData) { cbPtr in
          AudioConverterFillComplexBuffer(
            converter,
            { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
              guard let userData = inUserData else {
                ioNumberDataPackets.pointee = 0
                return noErr
              }
              let cb = userData.assumingMemoryBound(to: AudioEncoderInput.self)

              if cb.pointee.consumed {
                ioNumberDataPackets.pointee = 0
                return noErr
              }
              cb.pointee.consumed = true

              ioNumberDataPackets.pointee = UInt32(cb.pointee.srcSize / 4)
              ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: cb.pointee.srcData)
              ioData.pointee.mBuffers.mDataByteSize = cb.pointee.srcSize
              ioData.pointee.mBuffers.mNumberChannels = 1
              return noErr
            },
            cbPtr,
            &packetSize,
            &outputBufferList,
            &outputPacketDesc
          )
        }
      }

      guard status == noErr else {
        logger.warning("AAC-ELD encode error: \(status)")
        return nil
      }

      let encodedSize = Int(outputBufferList.mBuffers.mDataByteSize)
      guard encodedSize > 0 else { return nil }
      return Data(bytes: outputBuf.baseAddress!, count: encodedSize)
    }

    guard let aacData else { return }

    // Wrap in RFC 3640 AU header section (HomeKit expects this framing)
    guard let framedPayload = AUHeader.add(to: aacData) else { return }

    // Dispatch RTP send to rtpQueue so all audio RTP state (seq, timestamp,
    // stats) is accessed from a single queue, avoiding data races with RTCP.
    rtpQueue.async { [self] in
      sendAudioRTPPacket(payload: framedPayload)
    }
  }

  // MARK: - Audio RTP Send

  private nonisolated func sendAudioRTPPacket(payload: Data) {
    dispatchPrecondition(condition: .onQueue(rtpQueue))
    // Build 12-byte RTP header
    var header = Data(count: 12)
    header[0] = 0x80  // V=2
    header[1] = 0x80 | (audioPayloadType & 0x7F)  // M=1 (every AAC frame is a complete AU)
    header[2] = UInt8(audioRTPSeq >> 8)
    header[3] = UInt8(audioRTPSeq & 0xFF)
    header[4] = UInt8((audioRTPTimestamp >> 24) & 0xFF)
    header[5] = UInt8((audioRTPTimestamp >> 16) & 0xFF)
    header[6] = UInt8((audioRTPTimestamp >> 8) & 0xFF)
    header[7] = UInt8(audioRTPTimestamp & 0xFF)
    header[8] = UInt8((audioSSRC >> 24) & 0xFF)
    header[9] = UInt8((audioSSRC >> 16) & 0xFF)
    header[10] = UInt8((audioSSRC >> 8) & 0xFF)
    header[11] = UInt8(audioSSRC & 0xFF)

    audioRTPSeq &+= 1
    audioRTPTimestamp &+= UInt32(aacFrameSamples)  // 480 samples at 16kHz clock

    var rtpPacket = header
    rtpPacket.append(payload)

    // SRTP protect with audio context
    if let ctx = audioSRTPContext {
      guard let protected = ctx.protect(rtpPacket) else { return }
      rtpPacket = protected
    }

    audioPacketsSent += 1
    audioOctetsSent += payload.count
    let ts = audioRTPTimestamp
    let pkts = audioPacketsSent
    let octets = audioOctetsSent
    audioRTPStats.withLock {
      $0.timestamp = ts
      $0.packetsSent = pkts
      $0.octetsSent = octets
    }
    sendAudioUDP(rtpPacket)
  }

  // MARK: - Audio RTCP Sender Report

  nonisolated func startAudioRTCPTimer() {
    let timer = DispatchSource.makeTimerSource(queue: rtpQueue)
    timer.schedule(deadline: .now() + 1.0, repeating: 5.0)
    timer.setEventHandler { [weak self] in
      self?.sendAudioRTCPSenderReport()
    }
    timer.resume()
    self.audioRTCPTimer = timer
  }

  private nonisolated func sendAudioRTCPSenderReport() {
    guard let ctx = audioSRTPContext else { return }

    let stats = audioRTPStats.withLock { $0 }
    let sr = Self.buildRTCPSenderReport(
      ssrc: audioSSRC, rtpTimestamp: stats.timestamp,
      packetsSent: stats.packetsSent, octetsSent: stats.octetsSent)
    guard let srtcpPacket = ctx.protectRTCP(sr) else { return }
    sendAudioUDP(srtcpPacket)
    logger.debug(
      "Sent audio RTCP-SR: packets=\(stats.packetsSent) octets=\(stats.octetsSent)"
    )
  }

  // MARK: - Audio Decoder (AAC-ELD → PCM)

  nonisolated func setupAudioDecoder() {
    // Input: AAC-ELD, 16kHz, mono
    var inputDesc = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatMPEG4AAC_ELD,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: 480,
      mBytesPerFrame: 0,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 0,
      mReserved: 0
    )

    // Output: Linear PCM Float32, 16kHz, mono
    var outputDesc = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    var decoder: AudioConverterRef?
    let status = AudioConverterNew(&inputDesc, &outputDesc, &decoder)
    if status != noErr {
      logger.error("AudioConverter (decoder) create failed: \(status)")
      return
    }

    self.audioDecoder = decoder
    logger.info("AAC-ELD decoder created")
  }

  // MARK: - Audio Playback (AVAudioEngine)

  nonisolated func setupAudioPlayback() {
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()

    engine.attach(playerNode)

    // Connect player to main mixer with Float32/16kHz/mono format
    guard let format = playbackFormat else {
      logger.error("Failed to create audio format for playback")
      return
    }
    engine.connect(playerNode, to: engine.mainMixerNode, format: format)

    // Don't start the engine here — the capture session starts asynchronously
    // and will interrupt the audio session, killing the engine. Instead, we
    // start it lazily in ensureAudioEngineRunning() when we actually have
    // audio to play.
    self.audioEngine = engine
    self.audioPlayerNode = playerNode
    self.audioPlayerStarted = false
    logger.info("Audio playback engine prepared (will start on first audio)")
  }

  /// Ensure the AVAudioEngine is running. Call before scheduling buffers.
  /// The engine may have been interrupted by the capture session or audio route changes.
  private nonisolated func ensureAudioEngineRunning() -> Bool {
    guard let engine = audioEngine else { return false }
    if engine.isRunning { return true }
    do {
      try engine.start()
      logger.info("AVAudioEngine started")
      return true
    } catch {
      logger.error("AVAudioEngine start error: \(error)")
      return false
    }
  }

  // MARK: - Audio BSD Socket Send/Receive

  /// Send data via the BSD audio socket to the controller's audio port.
  private nonisolated func sendAudioUDP(_ data: Data) {
    guard audioSocketFD >= 0, var addr = controllerAudioAddr else { return }
    data.withUnsafeBytes { buf in
      guard let base = buf.baseAddress else { return }
      withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
          _ = sendto(
            audioSocketFD, base, buf.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
  }

  /// Called by GCD read source when data is available on the audio socket.
  nonisolated func readAudioSocket() {
    var buf = [UInt8](repeating: 0, count: 2048)
    while true {
      let n = recv(audioSocketFD, &buf, buf.count, 0)
      if n <= 0 { break }  // EAGAIN (no more data) or error
      // Distinguish RTP from RTCP per RFC 5761 §4: check payload type bits
      // (byte[1] bits 0-6, masking off the marker bit) against 72-76.
      guard n >= 12 else { continue }
      let pt = buf[1] & 0x7F
      if pt >= 72 && pt <= 76 {
        // SRTCP packet from controller (receiver report, etc.) — skip
        continue
      }
      let data = Data(buf[0..<n])
      handleIncomingAudioPacket(data)
    }
  }

  private nonisolated func handleIncomingAudioPacket(_ srtpData: Data) {
    dispatchPrecondition(condition: .onQueue(rtpQueue))
    guard let ctx = incomingSRTPContext else { return }
    guard !speakerMuted else { return }
    incomingAudioPacketCount += 1

    // SRTP unprotect
    guard let rtpPacket = ctx.unprotect(srtpData) else {
      logger.warning(
        "Failed to unprotect incoming audio SRTP packet (#\(self.incomingAudioPacketCount))")
      return
    }

    // Extract AAC-ELD payload from RTP (skip 12-byte header)
    guard rtpPacket.count > 12 else { return }
    var aacPayload = Data(rtpPacket[rtpPacket.startIndex + 12..<rtpPacket.endIndex])
    guard !aacPayload.isEmpty else { return }

    // Strip RFC 3640 AU header section if present.
    aacPayload = AUHeader.strip(from: aacPayload)

    guard !aacPayload.isEmpty else { return }

    // Decode AAC-ELD → PCM
    guard let decoder = audioDecoder else { return }

    let outputSamples = aacFrameSamples
    let outputBufferSize = outputSamples * 4  // Float32

    withUnsafeTemporaryAllocation(byteCount: outputBufferSize, alignment: 4) { outputBuf in
      var outputBufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 1,
          mDataByteSize: UInt32(outputBufferSize),
          mData: outputBuf.baseAddress
        )
      )

      var packetCount: UInt32 = UInt32(outputSamples)

      let status: OSStatus = aacPayload.withUnsafeBytes { aacBuf -> OSStatus in
        guard let aacBase = aacBuf.baseAddress else { return -1 }

        var cbData = AudioDecoderInput(
          srcData: aacBase,
          srcSize: UInt32(aacPayload.count),
          packetDesc: AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(aacPayload.count)
          ),
          consumed: false
        )

        return withUnsafeMutablePointer(to: &cbData) { cbPtr in
          AudioConverterFillComplexBuffer(
            decoder,
            { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
              guard let userData = inUserData else {
                ioNumberDataPackets.pointee = 0
                return noErr
              }
              let cb = userData.assumingMemoryBound(to: AudioDecoderInput.self)

              if cb.pointee.consumed {
                ioNumberDataPackets.pointee = 0
                return noErr
              }
              cb.pointee.consumed = true
              ioNumberDataPackets.pointee = 1

              ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: cb.pointee.srcData)
              ioData.pointee.mBuffers.mDataByteSize = cb.pointee.srcSize
              ioData.pointee.mBuffers.mNumberChannels = 1

              if let outDesc = outDataPacketDescription {
                let descOffset = MemoryLayout<AudioDecoderInput>.offset(of: \.packetDesc)!
                outDesc.pointee = userData.advanced(by: descOffset)
                  .assumingMemoryBound(to: AudioStreamPacketDescription.self)
              }
              return noErr
            },
            cbPtr,
            &packetCount,
            &outputBufferList,
            nil
          )
        }
      }

      let decodedSize = Int(outputBufferList.mBuffers.mDataByteSize)
      if status != noErr && decodedSize == 0 { return }
      guard decodedSize > 0, let playerNode = audioPlayerNode else { return }

      let sampleCount = decodedSize / 4
      if sampleCount < 10 { return }

      let gain = Float(speakerVolume) / 100.0

      guard let format = playbackFormat,
        let pcmBuffer = AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))
      else {
        return
      }

      pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
      outputBuf.baseAddress!.withMemoryRebound(to: Float.self, capacity: sampleCount) { src in
        if let channelData = pcmBuffer.floatChannelData?[0] {
          for i in 0..<sampleCount {
            channelData[i] = src[i] * gain
          }
        }
      }

      guard ensureAudioEngineRunning() else { return }
      playerNode.scheduleBuffer(pcmBuffer)
      if !audioPlayerStarted || !playerNode.isPlaying {
        playerNode.play()
        audioPlayerStarted = true
      }
    }
  }
}

// MARK: - Audio Converter Callback Data

/// Helper for passing PCM data through the AudioConverter encoder C callback.
private struct AudioEncoderInput {
  var srcData: UnsafeRawPointer?
  var srcSize: UInt32
  var consumed: Bool
}

/// Helper for passing compressed audio data + packet description through the AudioConverter decoder C callback.
private struct AudioDecoderInput {
  var srcData: UnsafeRawPointer?
  var srcSize: UInt32
  var packetDesc: AudioStreamPacketDescription
  var consumed: Bool
}
