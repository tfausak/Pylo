# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. See also [CONTRIBUTING.md](CONTRIBUTING.md) for project structure and build details.

## Build Commands

```bash
# Build
./scripts/build.sh

# Test
./scripts/test.sh

# Format (in-place)
./scripts/format.sh

# Lint
./scripts/lint.sh
```

Tests use Swift Testing framework (`@Test`, `#expect()`), not XCTest. The `IDERunDestination: Supported platforms` warning can be ignored.

## Architecture

Pylo is an iOS and macOS app that implements the **HomeKit Accessory Protocol (HAP)** from scratch, turning an iPhone or Mac into a HomeKit bridge with native accessories (flashlight, camera, sensors, siren, button).

### Protocol Stack

```
HomeKit Controller (Home.app)
  ↕ Bonjour discovery (_hap._tcp)
HAPServer (Network.framework NWListener)
  ↕ TCP connections
HAPConnection (HTTP/1.1 parser + TLV8/JSON framing)
  ↕ Pair-setup (SRP-6a via BigInt) → Pair-verify (Curve25519 ECDH)
  ↕ ChaCha20-Poly1305 encrypted session
Accessories (aid 1-9: bridge, lightbulb, camera, light sensor, motion sensor, contact sensor, occupancy sensor, siren, button)
```

### Key Files

**App (Pylo/)**

| File | Role |
|------|------|
| `PyloApp.swift` | `@main` entry point, `VideoQuality`/`MotionSensitivity`/`OccupancyCooldown` enums |
| `ContentView.swift` | Main SwiftUI view |
| `WelcomeView.swift` | Welcome/onboarding screen |
| `RunningView.swift` | Server running status view |
| `PairingView.swift` | Pairing QR code / setup code UI |
| `AccessoryCard.swift` | Reusable accessory card UI component |
| `Platform.swift` | Platform abstraction layer (iOS/macOS) |
| `HAPViewModel.swift` | Central coordinator: server lifecycle, accessory wiring, QR code helpers |
| `HAPAccessory.swift` | Lightbulb accessory (torch control, battery service) |
| `HAPCameraAccessory.swift` | Camera accessory: class, properties, characteristic read/write, IIDs/UUIDs |
| `  +StreamConfig.swift` | TLV8 config builders (supported/selected video/audio/recording configs) |
| `  +Streaming.swift` | Setup endpoints, RTP stream config, start/stop streaming, local IP |
| `  +Snapshot.swift` | Silent snapshot capture via `FrameGrabber` |
| `SirenPlayer.swift` | AVAudioEngine-based siren tone generation |
| `HAPTypes.swift` | Keychain helpers (`KeychainKeyStore`) |
| `HomeKitUUIDs.swift` | HAP short-form UUID mapping, verified against HomeKit constants |

**Packages/**

| Package | Key Files | Role |
|---------|-----------|------|
| `HAP` | `HAPServer.swift`, `HAPConnection.swift` | TCP listener, Bonjour, per-client HTTP parsing, encryption |
| `HAP` | `HAPAccessoryTypes.swift`, `HAPTypes.swift` | Accessory types (bridge, lightbulb, sensors, siren, button), core protocol definitions |
| `HAP` | `PairSetup.swift`, `PairVerify.swift` | SRP-6a pair-setup, Curve25519 pair-verify state machines |
| `HAP` | `PairingStore.swift`, `DeviceIdentity.swift`, `KeyStore.swift` | Pairing persistence, Ed25519 identity, keychain protocol |
| `HAP` | `CharacteristicsHandler.swift`, `PairingsHandler.swift` | GET/PUT /characteristics, pairing management |
| `HAP` | `HTTPRequest.swift`, `HTTPResponse.swift` | HTTP/1.1 request parser, response builder |
| `HAP` | `CharacteristicID.swift` | Characteristic identifier for subscription tracking |
| `HAP` | `BatteryState.swift`, `HAPSnapshotProvider.swift` | Battery characteristic values, camera snapshot protocol |
| `HAP` | `HAPDataStream.swift` | HomeKit Data Stream TCP listener and transport setup |
| `HAP` | `HDSConnection.swift` | HDS connection: ChaCha20 encryption, message framing, dataSend |
| `HAP` | `HDSMessage.swift` | HDS message encode/decode (event, request, response) |
| `HAP` | `HDSCodec.swift` | HDS binary codec for dicts, arrays, strings, ints, Data |
| `SRP` | `SRPServer.swift` | SRP-6a crypto (3072-bit group, RFC 5054) |
| `SRTP` | `SRTPContext.swift`, `AUHeader.swift` | SRTP encryption (AES-128-ICM + HMAC-SHA1-80), RFC 3640 AU headers |
| `TLV8` | `TLV8.swift` | HomeKit TLV8 binary codec |
| `FragmentedMP4` | `FragmentedMP4Writer.swift` | fMP4 segment generation for HKSV recording |
| `Locked` | `Locked.swift` | Thread-safe state wrapper (`os_unfair_lock`), shared by all packages |
| `Sensors` | `AmbientLightDetector.swift`, `BatteryMonitor.swift`, `MotionMonitor.swift`, `VideoMotionDetector.swift`, `OccupancySensor.swift`, `ProximitySensor.swift` | Device sensor abstractions (light, battery, motion, video motion, occupancy, proximity) |
| `Streaming` | `CameraStreamSession.swift` (+Audio, +RTCP), `MonitoringCaptureSession.swift` (+Audio), `AudioUtilities.swift`, `CaptureDelegates.swift`, `DeviceOrientationCache.swift` | Video capture, H.264 compression, RTP packetization, audio encoding, HKSV pre-buffering |

### Data Flow

- **HAPViewModel** owns the server, all accessories, and monitors. It publishes state to the SwiftUI `ContentView`.
- Accessories notify the server of state changes via `onStateChange` closures; the server pushes HAP EVENT messages to subscribed connections.
- **PairingStore** persists controller pairings to `pairings.json` in Application Support. **DeviceIdentity** stores the Ed25519 signing key and setup code in Keychain.

### Dependencies

- **BigInt** (SPM) — SRP-6a 3072-bit arithmetic
- Apple frameworks: Network, CryptoKit, AVFoundation, CoreMotion, VideoToolbox, AudioToolbox
