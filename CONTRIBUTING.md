# Contributing

## Build Commands

```bash
./scripts/build.sh      # Build
./scripts/test.sh       # Test
./scripts/format.sh     # Format (in-place)
./scripts/lint.sh       # Lint
```

Tests use the [Swift Testing](https://developer.apple.com/xcode/swift-testing/)
framework (`@Test`, `#expect()`), not XCTest.

## Project Structure

```
Pylo/                              iOS app
  PyloApp.swift                    @main entry point
  ContentView.swift                Main SwiftUI view
  PairingView.swift                Pairing QR code / setup code UI
  AccessoryCard.swift              Reusable accessory card component
  HAPViewModel.swift               Central coordinator (server lifecycle, accessory wiring)
  HAPCameraAccessory.swift         Camera accessory (+ StreamConfig, Streaming, Snapshot, JSON extensions)
  CameraStreamSession.swift        Live streaming pipeline (+ Audio, RTCP extensions)
  MonitoringCaptureSession.swift   HKSV idle pre-buffering (+ Audio extension)
  HAPAccessory.swift               Lightbulb accessory
  AmbientLightDetector.swift       Ambient light estimation from camera exposure
  VideoMotionDetector.swift        Camera-based motion detection
  MotionMonitor.swift              Accelerometer motion detection
  BatteryMonitor.swift             Battery level/charging state monitoring

Packages/
  HAP/                             HomeKit Accessory Protocol (server, pairing, encryption)
    HAPDataStream.swift            HomeKit Data Stream (TCP transport for HKSV)
    HDSConnection.swift            HDS connection (ChaCha20 encryption, message framing)
    HDSMessage.swift               HDS message encode/decode
    HDSCodec.swift                 HDS binary codec
  SRP/                             SRP-6a authentication (3072-bit)
  SRTP/                            SRTP encryption + RFC 3640 AU headers
  TLV8/                            HomeKit TLV8 binary codec
  FragmentedMP4/                   fMP4 segment generation for HKSV recording

PyloTests/                         Unit and integration tests
scripts/                           Build, test, format, and lint scripts
```

## Dependencies

- [BigInt](https://github.com/attaswift/BigInt) (SPM) — SRP-6a 3072-bit arithmetic
- Apple frameworks: Network, CryptoKit, AVFoundation, CoreMotion, VideoToolbox, AudioToolbox
