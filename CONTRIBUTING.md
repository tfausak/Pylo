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
Pylo/                              iOS + macOS app
  PyloApp.swift                    @main entry point
  ContentView.swift                Main SwiftUI view
  WelcomeView.swift                Welcome/onboarding screen
  RunningView.swift                Server running status view
  PairingView.swift                Pairing QR code / setup code UI
  AccessoryCard.swift              Reusable accessory card component
  Platform.swift                   Platform abstraction (iOS/macOS)
  HAPViewModel.swift               Central coordinator (server lifecycle, accessory wiring)
  HAPAccessory.swift               Lightbulb accessory
  HAPCameraAccessory.swift         Camera accessory (core class, characteristics, JSON)
    +StreamConfig.swift            TLV8 config builders (video/audio/recording)
    +Streaming.swift               RTP stream setup/teardown, local IP
    +Snapshot.swift                Silent snapshot capture via FrameGrabber
  SirenPlayer.swift                AVAudioEngine-based siren tone generation

Packages/
  HAP/                             HomeKit Accessory Protocol (server, pairing, encryption)
    HAPAccessoryTypes.swift        Accessory types (bridge, sensors, siren, button)
    HAPDataStream.swift            HomeKit Data Stream (TCP transport for HKSV)
    HDSConnection.swift            HDS connection (ChaCha20 encryption, message framing)
    HDSMessage.swift               HDS message encode/decode
    HDSCodec.swift                 HDS binary codec
  SRP/                             SRP-6a authentication (3072-bit)
  SRTP/                            SRTP encryption + RFC 3640 AU headers
  TLV8/                            HomeKit TLV8 binary codec
  FragmentedMP4/                   fMP4 segment generation for HKSV recording
  Locked/                          Thread-safe state wrapper (os_unfair_lock)
  Sensors/                         Device sensor abstractions (light, battery, motion, occupancy, proximity)
  Streaming/                       Video capture, H.264 encoding, RTP, audio, HKSV pre-buffering

PyloTests/                         Unit and integration tests
scripts/                           Build, test, format, and lint scripts
```

## Dependencies

- [BigInt](https://github.com/attaswift/BigInt) (SPM) — SRP-6a 3072-bit arithmetic
- Apple frameworks: Network, CryptoKit, AVFoundation, CoreMotion, VideoToolbox, AudioToolbox
