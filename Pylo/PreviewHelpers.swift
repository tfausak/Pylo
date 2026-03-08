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
    needsRestart: Bool = false,
    screenSaverEnabled: Bool = false,
    screenSaverDelay: TimeInterval = 60,
    keepScreenAwake: Bool = false
  ) -> HAPViewModel {
    let vm = HAPViewModel(skipRestore: true)
    vm.isRestoring = true
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
    vm.screenSaverEnabled = screenSaverEnabled
    vm.screenSaverDelay = screenSaverDelay
    vm.keepScreenAwake = keepScreenAwake
    vm.setupCode = "123-45-678"
    vm.setupID = "PYLO"
    vm.statusMessage = "Advertising as 'Pylo Bridge'"
    vm.selectedStreamCamera = CameraOption(id: "preview-back", name: "Back Camera", fNumber: 1.8)
    vm.availableCameras = [
      CameraOption(id: "preview-front", name: "Front Camera", fNumber: 2.2),
      CameraOption(id: "preview-back", name: "Back Camera", fNumber: 1.8),
    ]
    vm.isRestoring = false
    if running {
      if needsRestart {
        vm.startedConfig = AccessoryConfig(
          flashlightEnabled: !flashlightEnabled,
          selectedCameraID: vm.selectedStreamCamera?.id,
          motionEnabled: motionEnabled,
          microphoneEnabled: vm.microphoneEnabled
        )
      } else {
        vm.startedConfig = AccessoryConfig(from: vm)
      }
    }
    return vm
  }
}
