# HAP Flashlight — HomeKit Accessory PoC for iOS

Turn an old iPhone into a HomeKit-controllable light by exposing its
flashlight (torch) as a HAP (HomeKit Accessory Protocol) lightbulb.

## Project Setup

1. **Create a new Xcode project**
   - iOS → App
   - Interface: SwiftUI
   - Language: Swift
   - Product Name: `HAPFlashlight`
   - Bundle Identifier: e.g. `com.yourname.hapflashlight`

2. **Delete the generated `ContentView.swift` and `HAPFlashlightApp.swift`**
   (or whatever Xcode names them — we provide our own)

3. **Add all `.swift` files from this folder** to the Xcode project:
   - `HAPFlashlightApp.swift` — App entry point + SwiftUI UI
   - `HAPServer.swift` — TCP listener + Bonjour advertisement
   - `HAPConnection.swift` — Per-connection HTTP handling
   - `HAPAccessory.swift` — Accessory model + torch control
   - `HAPTypes.swift` — DeviceIdentity, PairingStore, EncryptionContext
   - `TLV8.swift` — TLV8 encoder/decoder
   - `PairSetup.swift` — Pair-setup handler (M1–M6)
   - `PairVerify.swift` — Pair-verify handler (M1–M4)
   - `PairingsHandler.swift` — Add/remove/list pairings
   - `CharacteristicsHandler.swift` — GET/PUT characteristics
   - `SRP.swift` — SRP-6a server (**needs implementation**)

4. **Add the BigInt dependency** (needed for SRP):
   - File → Add Package Dependencies
   - URL: `https://github.com/attaswift/BigInt.git`
   - Version: 5.3.0 or later

5. **Add `NSCameraUsageDescription`** to Info.plist:
   ```
   <key>NSCameraUsageDescription</key>
   <string>Used to control the flashlight as a HomeKit accessory.</string>
   ```

6. **Ensure "Local Network" permission** is granted (iOS will prompt
   automatically when the app tries to listen on a TCP port).

## What Works Now

- Bonjour advertisement (your device will appear in Home.app)
- Full HTTP routing for all HAP endpoints
- TLV8 encoding/decoding
- Pair-Verify (Curve25519 ECDH, all CryptoKit)
- Encrypted session handling (ChaCha20-Poly1305)
- Accessory database with lightbulb service
- Torch control via AVCaptureDevice
- GET/PUT /characteristics
- Pairings management
- SwiftUI status UI

## Implemented

- **SRP-6a** — Full implementation in `SRP.swift` using BigInt
- **Persist DeviceIdentity** — Ed25519 key pair and device ID saved to Keychain
- **Persist PairingStore** — Pairings saved to `Application Support/pairings.json`
- **EVENT notifications** — Push-based state updates via `EVENT/1.0 200 OK` frames

## Testing

1. Build and run on a physical iPhone (torch requires real hardware)
2. Tap "Start Server"
3. On another iOS device, open Home.app → Add Accessory
4. Choose "I Don't Have a Code or Cannot Scan"
5. Your device should appear as "iPhone Flashlight"
6. Tap it, then "Add Anyway" for the uncertified accessory prompt
7. Enter the setup code: `111-22-333`
8. Once paired, toggle the light from Home.app or ask Siri!

## Architecture

```
Home.app (controller)
    │
    │ TCP / _hap._tcp Bonjour
    │
    ▼
┌──────────────┐
│  HAPServer   │ ← NWListener + Bonjour
│              │
│  ┌─────────────────┐
│  │ HAPConnection   │ ← HTTP parsing, encryption
│  │                 │
│  │  PairSetup      │ ← SRP-6a exchange
│  │  PairVerify     │ ← Curve25519 ECDH
│  │  Characteristics │ ← Read/write values
│  └─────────────────┘
│              │
│  HAPAccessory │ ← Lightbulb service
│  (torch)      │   AVCaptureDevice
└──────────────┘
```
