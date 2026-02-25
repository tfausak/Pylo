import Foundation
import AVFoundation
import os

// MARK: - Accessory Category (Table 12-3 in HAP R2 spec)

enum HAPAccessoryCategory: Int {
    case other          = 1
    case bridge         = 2
    case fan            = 3
    case garageDoor     = 4
    case lightbulb      = 5
    case doorLock       = 6
    case outlet         = 7
    case `switch`       = 8
    case thermostat     = 9
    case sensor         = 10
    case securitySystem = 11
    case door           = 12
    case window         = 13
    case windowCovering = 14
    case programmableSwitch = 15
}

// MARK: - HAP Accessory

final class HAPAccessory {

    let name: String
    let model: String
    let manufacturer: String
    let serialNumber: String
    let firmwareRevision: String
    let category: HAPAccessoryCategory

    private let logger = Logger(subsystem: "com.example.hap", category: "Accessory")

    // Accessory ID (aid) — always 1 for a single-accessory server.
    let aid: Int = 1

    // MARK: - Lightbulb State

    private(set) var isOn: Bool = false {
        didSet { applyTorchState() }
    }

    private(set) var brightness: Int = 100 {
        didSet { applyTorchState() }
    }

    // MARK: - Light Sensor State

    private(set) var ambientLightLevel: Float = 1.0

    func updateAmbientLight(_ lux: Float) {
        ambientLightLevel = lux
        onStateChange?(aid, 12, lux)
    }

    /// Callback for notifying the server of state changes (for EVENT notifications).
    var onStateChange: ((_ aid: Int, _ iid: Int, _ value: Any) -> Void)?

    init(
        name: String = "HAP Flashlight",
        model: String = "iPhone Light",
        manufacturer: String = "HAP PoC",
        serialNumber: String = "000001",
        firmwareRevision: String = "1.0.0"
    ) {
        self.name = name
        self.model = model
        self.manufacturer = manufacturer
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.category = .lightbulb
    }

    // MARK: - Instance IDs (iid)
    // These must be stable. We assign them statically for our simple accessory.
    //
    // Service: Accessory Information (iid 1)
    //   - Identify:          iid 2
    //   - Manufacturer:      iid 3
    //   - Model:             iid 4
    //   - Name:              iid 5
    //   - Serial Number:     iid 6
    //   - Firmware Revision: iid 7
    //
    // Service: Lightbulb (iid 8)
    //   - On:                iid 9
    //   - Brightness:        iid 10
    //
    // Service: Light Sensor (iid 11)
    //   - Current Ambient Light Level: iid 12

    // MARK: - HAP Service/Characteristic UUIDs (shortened form)
    // HAP uses Apple-defined UUIDs of the form 000000XX-0000-1000-8000-0026BB765291.
    // The JSON representation uses just the short hex string.

    static let uuidAccessoryInformation = "3E"
    static let uuidIdentify            = "14"
    static let uuidManufacturer        = "20"
    static let uuidModel               = "21"
    static let uuidName                = "23"
    static let uuidSerialNumber        = "30"
    static let uuidFirmwareRevision    = "52"

    static let uuidLightbulb           = "43"
    static let uuidOn                  = "25"
    static let uuidBrightness          = "8"

    static let uuidLightSensor         = "84"
    static let uuidAmbientLightLevel   = "6B"

    // MARK: - Read Characteristic

    func readCharacteristic(iid: Int) -> Any? {
        switch iid {
        case 3: return manufacturer
        case 4: return model
        case 5: return name
        case 6: return serialNumber
        case 7: return firmwareRevision
        case 9: return isOn
        case 10: return brightness
        case 12: return ambientLightLevel
        default: return nil
        }
    }

    // MARK: - Write Characteristic

    /// Returns true if the write was accepted.
    @discardableResult
    func writeCharacteristic(iid: Int, value: Any) -> Bool {
        switch iid {
        case 2:
            // Identify
            identify()
            return true
        case 9:
            // On (bool)
            if let v = value as? Bool {
                isOn = v
                onStateChange?(aid, iid, v)
                logger.info("Light \(v ? "ON" : "OFF")")
                return true
            } else if let v = value as? Int {
                isOn = (v != 0)
                onStateChange?(aid, iid, isOn)
                return true
            }
            return false
        case 10:
            // Brightness (int 0-100)
            if let v = value as? Int {
                brightness = max(0, min(100, v))
                onStateChange?(aid, iid, brightness)
                logger.info("Brightness: \(self.brightness)%")
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: - Identify

    func identify() {
        logger.info("Identify requested — blinking torch")
        // Blink the torch 3 times
        Task { @MainActor in
            for _ in 0..<3 {
                setTorch(on: true, level: 1.0)
                try? await Task.sleep(nanoseconds: 200_000_000)
                setTorch(on: false, level: 0)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    // MARK: - Torch Control

    private func applyTorchState() {
        let level = isOn ? Float(brightness) / 100.0 : 0.0
        Task { @MainActor in
            setTorch(on: isOn, level: level)
        }
    }

    @MainActor
    private func setTorch(on: Bool, level: Float) {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else {
            logger.warning("No torch available on this device")
            return
        }

        do {
            try device.lockForConfiguration()
            if on && level > 0 {
                try device.setTorchModeOn(level: max(0.01, level)) // min level is ~0.01
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("Torch error: \(error)")
        }
    }

    // MARK: - JSON Serialization (for GET /accessories)

    func toJSON() -> [String: Any] {
        [
            "aid": aid,
            "services": [
                // Accessory Information Service
                [
                    "iid": 1,
                    "type": Self.uuidAccessoryInformation,
                    "characteristics": [
                        characteristicJSON(iid: 2, type: Self.uuidIdentify, format: "bool",
                                           perms: ["pw"], value: nil),
                        characteristicJSON(iid: 3, type: Self.uuidManufacturer, format: "string",
                                           perms: ["pr"], value: manufacturer),
                        characteristicJSON(iid: 4, type: Self.uuidModel, format: "string",
                                           perms: ["pr"], value: model),
                        characteristicJSON(iid: 5, type: Self.uuidName, format: "string",
                                           perms: ["pr"], value: name),
                        characteristicJSON(iid: 6, type: Self.uuidSerialNumber, format: "string",
                                           perms: ["pr"], value: serialNumber),
                        characteristicJSON(iid: 7, type: Self.uuidFirmwareRevision, format: "string",
                                           perms: ["pr"], value: firmwareRevision),
                    ]
                ],
                // Lightbulb Service
                [
                    "iid": 8,
                    "type": Self.uuidLightbulb,
                    "characteristics": [
                        characteristicJSON(iid: 9, type: Self.uuidOn, format: "bool",
                                           perms: ["pr", "pw", "ev"], value: isOn),
                        characteristicJSON(iid: 10, type: Self.uuidBrightness, format: "int",
                                           perms: ["pr", "pw", "ev"], value: brightness,
                                           minValue: 0, maxValue: 100, unit: "percentage"),
                    ]
                ],
                // Light Sensor Service
                [
                    "iid": 11,
                    "type": Self.uuidLightSensor,
                    "characteristics": [
                        characteristicJSON(iid: 12, type: Self.uuidAmbientLightLevel, format: "float",
                                           perms: ["pr", "ev"], value: ambientLightLevel,
                                           minValue: Float(0.0001), maxValue: Float(100000), unit: "lux"),
                    ]
                ],
            ]
        ]
    }

    private func characteristicJSON(
        iid: Int,
        type: String,
        format: String,
        perms: [String],
        value: Any?,
        minValue: Any? = nil,
        maxValue: Any? = nil,
        unit: String? = nil
    ) -> [String: Any] {
        var json: [String: Any] = [
            "iid": iid,
            "type": type,
            "format": format,
            "perms": perms,
        ]
        if let value { json["value"] = value }
        if let minValue { json["minValue"] = minValue }
        if let maxValue { json["maxValue"] = maxValue }
        if let unit { json["unit"] = unit }
        return json
    }
}
