@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import HAP
import Locked
import Streaming
import TLV8
import os

// MARK: - Streaming

extension HAPCameraAccessory {

  // MARK: - Streaming Status

  func streamingStatusTLV() -> Data {
    var b = TLV8.Builder()
    let status: UInt8 = hasActiveStreamSession ? 1 : 0  // 0=Available, 1=InUse, 2=Unavailable
    b.add(0x01, byte: status)
    return b.build()
  }

  // MARK: - Setup Endpoints

  func handleSetupEndpoints(_ value: HAPValue) -> Bool {
    guard case .string(let b64) = value, let data = Data(base64Encoded: b64) else { return false }
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]

    var sessionID = Data()
    var controllerAddress = ""
    var controllerVideoPort: UInt16 = 0
    var controllerAudioPort: UInt16 = 0
    var videoSRTPKey = Data()
    var videoSRTPSalt = Data()
    var audioSRTPKey = Data()
    var audioSRTPSalt = Data()

    for (tag, val) in tlvs {
      switch tag {
      case 0x01: sessionID = val
      case 0x03:  // Controller address
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        for (stag, sval) in sub {
          switch stag {
          case 0x02: controllerAddress = String(data: sval, encoding: .utf8) ?? ""
          case 0x03:
            if sval.count >= 2 {
              controllerVideoPort =
                UInt16(sval[sval.startIndex]) | UInt16(sval[sval.startIndex + 1]) << 8
            }
          case 0x04:
            if sval.count >= 2 {
              controllerAudioPort =
                UInt16(sval[sval.startIndex]) | UInt16(sval[sval.startIndex + 1]) << 8
            }
          default: break
          }
        }
      case 0x04:  // Video SRTP params
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        for (stag, sval) in sub {
          switch stag {
          case 0x02: videoSRTPKey = sval
          case 0x03: videoSRTPSalt = sval
          default: break
          }
        }
      case 0x05:  // Audio SRTP params
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        for (stag, sval) in sub {
          switch stag {
          case 0x02: audioSRTPKey = sval
          case 0x03: audioSRTPSalt = sval
          default: break
          }
        }
      default: break
      }
    }

    logger.info(
      "SetupEndpoints: controller=\(controllerAddress):\(controllerVideoPort)/\(controllerAudioPort)"
    )

    // Atomically detach any existing session to avoid racing with another device.
    // The old session is stopped without notifying HomeKit — the controller holding
    // that stream will see it go stale and time out. A proper HAP implementation
    // would send a StreamingStatus=0 event for the old session, but single-stream
    // devices typically just replace the session silently.
    if let oldSession = detachStreamSession() {
      logger.info("Replacing existing stream session for new SetupEndpoints request")
      oldSession.stopStreaming()
    }

    let videoSSRC = UInt32.random(in: 1...UInt32.max)
    let audioSSRC = UInt32.random(in: 1...UInt32.max)

    // Determine local IP address -- must be on the same subnet as the controller
    let localAddress = Self.localIPAddress(matching: controllerAddress) ?? "0.0.0.0"

    // Allocate UDP ports -- video uses N (RTP) and N+1 (RTCP),
    // audio uses N+2 (RTP) and N+3 (RTCP). Reserve room for all four ports.
    // Collision probability is ~1/10000; bind failure is handled in startStreaming()
    // (returns false → session cleared → controller retries setup).
    // A pre-bind check could eliminate this, but would require creating and closing
    // UDP sockets here just to probe — not worth the complexity for this failure rate.
    let videoPort: UInt16 = UInt16.random(in: 50000...59994)
    let audioPort: UInt16 = videoPort + 2

    logger.info("SetupEndpoints response: local=\(localAddress):\(videoPort) SSRC=\(videoSSRC)")

    // Create the stream session -- both sides use the SAME SRTP keys
    let session = CameraStreamSession(
      sessionID: sessionID,
      controllerAddress: controllerAddress,
      controllerVideoPort: controllerVideoPort,
      controllerAudioPort: controllerAudioPort,
      videoSRTPKey: videoSRTPKey,
      videoSRTPSalt: videoSRTPSalt,
      audioSRTPKey: audioSRTPKey,
      audioSRTPSalt: audioSRTPSalt,
      localAddress: localAddress,
      localVideoPort: videoPort,
      localAudioPort: audioPort,
      videoSSRC: videoSSRC,
      audioSSRC: audioSSRC
    )
    self.streamSession = session

    // Build response TLV8 -- echo back the controller's SRTP keys
    // Both sides use the same shared key material
    var addrTLV = TLV8.Builder()
    addrTLV.add(0x01, byte: 0x00)  // IPv4
    addrTLV.add(0x02, Data(localAddress.utf8))
    addrTLV.add(0x03, uint16: videoPort)
    addrTLV.add(0x04, uint16: audioPort)

    var videoSRTPTLV = TLV8.Builder()
    videoSRTPTLV.add(0x01, byte: 0x00)  // AES_CM_128_HMAC_SHA1_80
    videoSRTPTLV.add(0x02, videoSRTPKey)
    videoSRTPTLV.add(0x03, videoSRTPSalt)

    var audioSRTPTLV = TLV8.Builder()
    audioSRTPTLV.add(0x01, byte: 0x00)
    audioSRTPTLV.add(0x02, audioSRTPKey)
    audioSRTPTLV.add(0x03, audioSRTPSalt)

    var response = TLV8.Builder()
    response.add(0x01, sessionID)
    response.add(0x02, byte: 0x00)  // Status: Success
    response.add(0x03, tlv: addrTLV)
    response.add(0x04, tlv: videoSRTPTLV)
    response.add(0x05, tlv: audioSRTPTLV)
    response.add(0x06, uint32: videoSSRC)
    response.add(0x07, uint32: audioSSRC)

    setupEndpointsResponse = response.build()
    return true
  }

  // MARK: - Selected RTP Stream Configuration (START/STOP/RECONFIGURE)

  func handleSelectedRTPStreamConfig(_ value: HAPValue) -> Bool {
    guard case .string(let b64) = value, let data = Data(base64Encoded: b64) else { return false }
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]

    // Parse session control
    var sessionID = Data()
    var command: UInt8 = 0
    for (tag, val) in tlvs {
      if tag == 0x01 {
        let sub = TLV8.decode(val) as [(UInt8, Data)]
        for (stag, sval) in sub {
          switch stag {
          case 0x01: sessionID = sval
          case 0x02: if let c = sval.first { command = c }
          default: break
          }
        }

        switch command {
        case 1:  // START
          logger.info("Stream START requested")
          // Parse selected video params and RTP params
          var width: UInt16 = 1280
          var height: UInt16 = 720
          var fps: UInt8 = 30
          var maxBitrate: Int = 2000
          var payloadType: UInt8 = 99
          var audioPayloadType: UInt8 = 110
          for (ptag, pval) in tlvs {
            if ptag == 0x02 {  // Selected video parameters
              let vsub = TLV8.decode(pval) as [(UInt8, Data)]
              for (vtag, vval) in vsub {
                switch vtag {
                case 0x03:  // Video attributes (width, height, fps)
                  let attrSub = TLV8.decode(vval) as [(UInt8, Data)]
                  for (atag, aval) in attrSub {
                    switch atag {
                    case 0x01:
                      if aval.count >= 2 {
                        width =
                          UInt16(aval[aval.startIndex]) | UInt16(aval[aval.startIndex + 1]) << 8
                      }
                    case 0x02:
                      if aval.count >= 2 {
                        height =
                          UInt16(aval[aval.startIndex]) | UInt16(aval[aval.startIndex + 1]) << 8
                      }
                    case 0x03: if let f = aval.first { fps = f }
                    default: break
                    }
                  }
                case 0x04:  // Video RTP parameters (PT, SSRC, bitrate)
                  let rtpSub = TLV8.decode(vval) as [(UInt8, Data)]
                  for (rtag, rval) in rtpSub {
                    switch rtag {
                    case 0x01: if let pt = rval.first { payloadType = pt }  // Payload type
                    case 0x03:
                      if rval.count >= 2 {
                        maxBitrate = Int(
                          UInt16(rval[rval.startIndex]) | UInt16(rval[rval.startIndex + 1]) << 8)
                      }
                    default: break
                    }
                  }
                default: break
                }
              }
            } else if ptag == 0x03 {  // Selected audio parameters
              let asub = TLV8.decode(pval) as [(UInt8, Data)]
              for (atag, aval) in asub {
                if atag == 0x03 {  // Audio RTP parameters
                  let rtpSub = TLV8.decode(aval) as [(UInt8, Data)]
                  for (rtag, rval) in rtpSub {
                    if rtag == 0x01, let pt = rval.first { audioPayloadType = pt }
                  }
                }
              }
            }
          }
          logger.info(
            "Selected video: \(width)x\(height)@\(fps)fps, \(maxBitrate)kbps, PT=\(payloadType), audioPT=\(audioPayloadType)"
          )
          startStreaming(
            width: Int(width), height: Int(height), fps: Int(fps), bitrate: maxBitrate,
            payloadType: payloadType, audioPayloadType: audioPayloadType)

        case 0:  // END
          logger.info("Stream STOP requested")
          stopStreaming()
        case 2:  // RECONFIGURE -- not fully implemented; stop stream as fallback
          logger.warning("Stream RECONFIGURE not implemented -- stopping stream")
          stopStreaming()
        default:
          break
        }
      }
    }

    // Build write-response TLV echoing the session ID back to the controller.
    // HAP requires this so the controller can correlate the response to the
    // session it sent. Without it, some controllers show a camera-slash icon.
    var response = TLV8.Builder()
    var sessionControl = TLV8.Builder()
    sessionControl.add(0x01, sessionID)
    sessionControl.add(0x02, byte: command)
    response.add(0x01, tlv: sessionControl)
    selectedRTPStreamConfigResponse = response.build()

    return true
  }

  // MARK: - Streaming Control

  func startStreaming(
    width: Int, height: Int, fps: Int, bitrate: Int, payloadType: UInt8,
    audioPayloadType: UInt8 = 110
  ) {
    guard let session = streamSession else {
      logger.error("No stream session configured")
      return
    }

    guard let camera = resolveCamera() else {
      logger.error("No camera available for streaming")
      return
    }

    let settings = audioSettings.value
    session.isMuted = settings.isMuted
    session.speakerMuted = settings.speakerMuted
    session.speakerVolume = settings.speakerVolume
    session.videoMotionDetector = videoMotionDetector
    session.ambientLightDetector = ambientLightDetector
    session.onSnapshotFrame = { [weak self] cgImage in
      self?.cachedFrame = cgImage
    }

    // Hand off the monitoring session's AVCaptureSession for reuse if available.
    // This avoids the ~500ms cold-start of creating a new session. If no monitoring
    // session is running, fall back to stopping it and creating a fresh session.
    onStreamingStart?()

    let existingSession = onMonitoringSessionHandoff?()
    if existingSession == nil {
      onMonitoringCaptureNeeded?(false, nil)
    }

    let effectiveBitrate = max(bitrate, minBitrate)
    let rotation = currentRotation()
    logger.info(
      "Bitrate: negotiated=\(bitrate)kbps, minimum=\(self.minBitrate)kbps, effective=\(effectiveBitrate)kbps, rotation=\(rotation.angle)\u{00B0}"
    )
    let started = session.startStreaming(
      width: width, height: height, fps: fps, bitrate: effectiveBitrate, payloadType: payloadType,
      audioPayloadType: audioPayloadType, camera: camera, rotationAngle: rotation.angle,
      swapDimensions: rotation.swapDimensions, existingCaptureSession: existingSession,
      microphoneEnabled: microphoneEnabled)
    if !started {
      logger.error("Stream session failed to start — clearing session")
      clearStreamSession(ifIdenticalTo: session)
      onMonitoringCaptureNeeded?(true, nil)
    } else {
      // Dispatch on captureQueue so this runs after startRunning() completes
      // on cold start (where startRunning is dispatched async on captureQueue).
      let callback = onStreamingDidStart
      session.captureQueue.async { callback?() }
    }
    // Notify subscribers of the updated streaming status. This is correct even after
    // a failure: clearStreamSession sets streamSession=nil, so streamingStatusTLV()
    // returns status=0 (Available), which is the right thing to report.
    onStateChange?(
      aid, Self.iidStreamingStatus, .string(streamingStatusTLV().base64EncodedString()))
  }

  func stopStreaming() {
    // Hand off the AVCaptureSession back to monitoring if recording is armed,
    // so it can resume without a cold-start.
    let recordingArmed = hksvState.withLock({ $0.recordingActive }) != 0
    // Atomically detach the session to avoid racing with another device
    let session = detachStreamSession()
    let handBackSession: AVCaptureSession?
    if recordingArmed {
      handBackSession = session?.handoff()
    } else {
      session?.stopStreaming()
      handBackSession = nil
    }
    onStateChange?(
      aid, Self.iidStreamingStatus, .string(streamingStatusTLV().base64EncodedString()))
    // Resume monitoring capture — with HKSV features if recording is armed,
    // or in sensor-only mode for light/occupancy/snapshot caching.
    onMonitoringCaptureNeeded?(recordingArmed, handBackSession)
  }

  // MARK: - Resolve Camera

  /// Resolve the selected camera device, falling back to the default back wide-angle.
  func resolveCamera() -> AVCaptureDevice? {
    if let id = selectedCameraID, let device = AVCaptureDevice(uniqueID: id) {
      return device
    }
    #if os(iOS)
      return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    #elseif os(macOS)
      return AVCaptureDevice.default(for: .video)
    #endif
  }

  // MARK: - Utility

  /// Returns the local IPv4 address on the same subnet as `peerAddress`.
  /// Uses the interface's actual netmask for proper subnet comparison (works
  /// with any CIDR prefix, not just /24). Falls back to any private address
  /// on en0 (WiFi) if no subnet match found.
  static func localIPAddress(matching peerAddress: String = "") -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    // Parse the peer address to a binary IPv4 address for subnet comparison
    var peerAddr = in_addr()
    let hasPeer = inet_pton(AF_INET, peerAddress, &peerAddr) == 1

    var subnetMatch: String?
    var wifiAddress: String?
    var anyPrivate: String?

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
      let flags = Int32(ptr.pointee.ifa_flags)
      guard (flags & (IFF_UP | IFF_RUNNING)) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
      let addr = ptr.pointee.ifa_addr.pointee
      guard addr.sa_family == UInt8(AF_INET) else { continue }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
          &hostname, socklen_t(hostname.count),
          nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let ip = String(
        decoding: hostname.map { UInt8(bitPattern: $0) }.prefix(while: { $0 != 0 }), as: UTF8.self)
      // RFC-1918 private ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
      let isPrivate: Bool = {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
        if ip.hasPrefix("172.") {
          let parts = ip.split(separator: ".")
          if parts.count >= 2, let second = Int(parts[1]) {
            return second >= 16 && second <= 31
          }
        }
        return false
      }()
      guard isPrivate else { continue }

      let ifName = String(cString: ptr.pointee.ifa_name)

      // Best: same subnet as the controller (using actual netmask)
      if hasPeer, subnetMatch == nil,
        let maskPtr = ptr.pointee.ifa_netmask
      {
        let localAddr = withUnsafePointer(to: ptr.pointee.ifa_addr.pointee) { rawAddr in
          rawAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
        let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          $0.pointee.sin_addr
        }
        if (localAddr.s_addr & mask.s_addr) == (peerAddr.s_addr & mask.s_addr) {
          subnetMatch = ip
        }
      }
      // Good: WiFi interface
      if ifName == "en0", wifiAddress == nil {
        wifiAddress = ip
      }
      // Fallback: any private address
      if anyPrivate == nil {
        anyPrivate = ip
      }
    }
    return subnetMatch ?? wifiAddress ?? anyPrivate
  }

  // MARK: - Setup Data Stream

  func handleSetupDataStream(_ value: HAPValue, sharedSecret: SharedSecret?) -> Bool {
    guard case .string(let b64) = value, let data = Data(base64Encoded: b64) else { return false }
    logger.debug("SetupDataStreamTransport: \(data.count) bytes")
    // NOTE: onSetupDataStream writes setupDataStreamResponse via a callback, but
    // writeCharacteristic returns true synchronously. If the callback is nil or
    // never fires, the next read of setupDataStreamResponse will serve stale data.
    // This is acceptable because the HAP server reads the response immediately
    // after writeCharacteristic returns (same call stack), and HAPDataStream's
    // setupTransport is synchronous — the callback fires inline before we return.
    onSetupDataStream?(
      data,
      sharedSecret,
      { [weak self] response in
        self?.setupDataStreamResponse = response
      })
    return true
  }
}
