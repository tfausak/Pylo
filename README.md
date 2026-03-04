# Pylo

Turn an old iPhone into a HomeKit bridge exposing its hardware as native
accessories:

- **Flashlight**:
  controllable lightbulb with brightness
- **Camera**:
  live H.264 video streaming with HomeKit Secure Video (HKSV) recording
- **Light Sensor**:
  ambient light level estimation from camera auto-exposure
- **Motion Sensor**:
  accelerometer-based and camera-based motion detection
- **Battery**:
  battery level and charging state as a HAP service on each accessory

## How It Works

Pylo implements the HomeKit Accessory Protocol (HAP) over IP directly on the
device — no external server or HomeKit SDK required. It advertises as a HAP
bridge via Bonjour and handles pairing, encryption, and accessory communication
natively using Apple frameworks.

## Requirements

- Physical iPhone (torch and sensors need real hardware)
- Xcode 16+

## Setup

1. Open `Pylo.xcodeproj` in Xcode
2. Build and run on a physical device
3. In Home.app on another device: Add Accessory → "More options ..."
4. Scan the QR code shown in the app, or enter the setup code

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build commands, project structure,
and development details.

## License

[0BSD](LICENSE.txt)

## Privacy

[Privacy Policy](PRIVACY.md)
