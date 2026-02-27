# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

Pylo is an iOS app that implements the **HomeKit Accessory Protocol (HAP)** from scratch, turning an old iPhone into a HomeKit bridge with native accessories (flashlight, camera, ambient light sensor, motion sensor).

### Protocol Stack

```
HomeKit Controller (Home.app)
  ↕ Bonjour discovery (_hap._tcp)
HAPServer (Network.framework NWListener)
  ↕ TCP connections
HAPConnection (HTTP/1.1 parser + TLV8/JSON framing)
  ↕ Pair-setup (SRP-6a via BigInt) → Pair-verify (Curve25519 ECDH)
  ↕ ChaCha20-Poly1305 encrypted session
Accessories (aid 1-5: bridge, lightbulb, camera, light sensor, motion sensor)
```

### Key Files

| File | Role |
|------|------|
| `Pylo/PyloApp.swift` | App entry point, `HAPViewModel` (central coordinator), `ContentView` (SwiftUI UI) |
| `Pylo/HAPServer.swift` | TCP listener + Bonjour advertisement |
| `Pylo/HAPConnection.swift` | Per-client TCP connection, HTTP parsing, encryption layer |
| `Pylo/HAPAccessory.swift` | `HAPAccessoryProtocol`, lightbulb accessory (torch control) |
| `Pylo/HAPCameraAccessory.swift` | Camera accessory: TLV8 negotiation, snapshot capture, HAP service definition |
| `Pylo/CameraStreamSession.swift` | Camera streaming pipeline: video capture, H.264, RTP, BSD sockets, audio encode/decode |
| `Pylo/SRTPContext.swift` | SRTP encryption/authentication (AES-128-ICM + HMAC-SHA1-80, RFC 3711) |
| `Pylo/AUHeader.swift` | RFC 3640 AU header helpers for AAC-ELD framing |
| `Pylo/HAPTypes.swift` | Keychain helpers, `DeviceIdentity`, `PairingStore` |
| `Pylo/PairSetup.swift` | SRP-6a pair-setup state machine |
| `Pylo/PairVerify.swift` | Curve25519 ECDH pair-verify |
| `Pylo/SRP.swift` | SRP-6a crypto (3072-bit group, RFC 5054) |
| `Pylo/TLV8.swift` | HomeKit TLV8 binary codec |
| `Pylo/CharacteristicsHandler.swift` | GET/PUT /characteristics |
| `Pylo/PairingsHandler.swift` | Pairing management |
| `Pylo/AmbientLightMonitor.swift` | Camera auto-exposure metadata → lux |
| `Pylo/MotionMonitor.swift` | Accelerometer threshold detection |

### Data Flow

- **HAPViewModel** owns the server, all accessories, and monitors. It publishes state to the SwiftUI `ContentView`.
- Accessories notify the server of state changes via `onStateChange` closures; the server pushes HAP EVENT messages to subscribed connections.
- **PairingStore** persists controller pairings to `pairings.json` in Application Support. **DeviceIdentity** stores the Ed25519 signing key and setup code in Keychain.

### Dependencies

- **BigInt** (SPM) — SRP-6a 3072-bit arithmetic
- Apple frameworks: Network, CryptoKit, AVFoundation, CoreMotion, VideoToolbox, AudioToolbox
