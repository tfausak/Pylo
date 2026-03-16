import SwiftUI

extension HAPViewModel {
  static func preview(
    running: Bool = false,
    paired: Bool = false,
    lightOn: Bool = false,
    brightness: Int = 100,
    flashlightEnabled: Bool = true,
    motionEnabled: Bool = true,
    motionDetected: Bool = false,
    cameraStreaming: Bool = false,
    contactEnabled: Bool = false,
    contactDetected: Bool = false,
    occupancyEnabled: Bool = false,
    occupancyDetected: Bool = false,
    keepScreenAwake: Bool = true,
    sirenEnabled: Bool = false,
    sirenActive: Bool = false
  ) -> HAPViewModel {
    let vm = HAPViewModel(skipRestore: true)
    vm.withRestoring {
      vm.isRunning = running
      vm.hasPairings = paired
      vm.isLightOn = lightOn
      vm.brightness = brightness
      vm.flashlightEnabled = flashlightEnabled
      vm.motionEnabled = motionEnabled
      vm.isMotionDetected = motionDetected
      vm.isMotionAvailable = true
      vm.hasCamera = true
      vm.hasTorch = true
      vm.hasAccelerometer = true
      vm.isCameraStreaming = cameraStreaming
      vm.contactEnabled = contactEnabled
      vm.isContactDetected = contactDetected
      vm.hasProximity = true
      vm.occupancyEnabled = occupancyEnabled
      vm.isOccupancyDetected = occupancyDetected
      vm.keepScreenAwake = keepScreenAwake
      vm.sirenEnabled = sirenEnabled
      vm.isSirenActive = sirenActive
      vm.setupCode = "123-45-678"
      vm.setupID = "PYLO"
      vm.statusMessage = "Advertising as 'Pylo Bridge'"
      vm.selectedStreamCamera = CameraOption(id: "preview-back", name: "Back Camera", fNumber: 1.8)
      vm.availableCameras = [
        CameraOption(id: "preview-front", name: "Front Camera", fNumber: 2.2),
        CameraOption(id: "preview-back", name: "Back Camera", fNumber: 1.8),
      ]
    }
    if running {
      vm.startedConfig = AccessoryConfig(from: vm)
    }
    return vm
  }
}
