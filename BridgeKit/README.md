# BridgeKit

Turn an old iPhone into a HomeKit bridge exposing its hardware as native accessories:

- **Flashlight** — controllable lightbulb with brightness
- **Camera** — live H.264 video streaming via HomeKit Secure Video (SRTP)
- **Ambient Light Sensor** — lux readings derived from a camera feed
- **Motion Sensor** — accelerometer-based motion detection

## How It Works

BridgeKit implements the HomeKit Accessory Protocol (HAP) over IP directly on the device — no external server or HomeKit SDK required. It advertises as a HAP bridge via Bonjour (`_hap._tcp`) and handles pairing, encryption, and accessory communication natively using Apple frameworks (Network.framework, CryptoKit, AVFoundation, CoreMotion).

## Requirements

- Physical iPhone (torch and sensors need real hardware)
- Xcode 16+
- [BigInt](https://github.com/attaswift/BigInt) Swift package (for SRP-6a)

## Setup

1. Open `BridgeKit.xcodeproj` in Xcode
2. Build and run on a physical device
3. Tap **Start Server**
4. In Home.app on another device: Add Accessory → "I Don't Have a Code or Cannot Scan"
5. Scan the QR code shown in the app, or enter the setup code `111-22-333`
