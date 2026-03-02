# Pylo

Turn an old iPhone into a HomeKit bridge exposing its hardware as native accessories:

- **Flashlight** — controllable lightbulb with brightness
- **Camera** — live H.264 video streaming with HomeKit Secure Video (HKSV) recording
- **Motion Sensor** — accelerometer-based and camera-based motion detection

## How It Works

Pylo implements the HomeKit Accessory Protocol (HAP) over IP directly on the device — no external server or HomeKit SDK required. It advertises as a HAP bridge via Bonjour (`_hap._tcp`) and handles pairing, encryption, and accessory communication natively using Apple frameworks (Network.framework, CryptoKit, AVFoundation, CoreMotion).

### Project Structure

```
Pylo/                          App target
  PyloApp.swift                @main entry point
  HAPViewModel.swift           Central coordinator (server lifecycle, accessory wiring)
  HAPCameraAccessory.swift     Camera accessory (+ StreamConfig, Streaming, Snapshot, JSON extensions)
  CameraStreamSession.swift    Live streaming pipeline (+ Audio, RTCP extensions)
  MonitoringCaptureSession.swift  HKSV idle pre-buffering (+ Audio extension)
  HAPAccessory.swift           Lightbulb accessory
  VideoMotionDetector.swift    Camera-based motion detection
  MotionMonitor.swift          Accelerometer motion detection

Packages/
  HAP/                         HomeKit Accessory Protocol (server, pairing, encryption)
    HAPDataStream.swift        HomeKit Data Stream (TCP transport for HKSV)
    HDSConnection.swift        HDS connection (ChaCha20 encryption, message framing)
    HDSMessage.swift           HDS message encode/decode
    HDSCodec.swift             HDS binary codec
  SRP/                         SRP-6a authentication (3072-bit)
  SRTP/                        SRTP encryption + RFC 3640 AU headers
  TLV8/                        HomeKit TLV8 binary codec
  FragmentedMP4/               fMP4 segment generation for HKSV recording
```

## Requirements

- Physical iPhone (torch and sensors need real hardware)
- Xcode 16+
- [BigInt](https://github.com/attaswift/BigInt) Swift package (for SRP-6a)

## Setup

1. Open `Pylo.xcodeproj` in Xcode
2. Build and run on a physical device
3. Tap **Start Server**
4. In Home.app on another device: Add Accessory → "I Don't Have a Code or Cannot Scan"
5. Scan the QR code shown in the app, or enter the setup code `111-22-333`
