import SwiftUI

// MARK: - Preview Factories

extension HAPViewModel {
  /// Creates a ViewModel configured for Xcode Previews.
  /// Side effects (UserDefaults writes, monitor restarts) are suppressed via `isRestoring`.
  static func preview(
    running: Bool = false,
    starting: Bool = false,
    paired: Bool = false,
    lightOn: Bool = false,
    brightness: Int = 100,
    flashlightEnabled: Bool = true,
    motionEnabled: Bool = true,
    motionDetected: Bool = false,
    cameraStreaming: Bool = false,
    ambientLux: Float = 12.3,
    needsRestart: Bool = false,  // simulated by mismatching startedConfig
    screenSaverEnabled: Bool = false,
    screenSaverDelay: TimeInterval = 60,
    keepScreenAwake: Bool = false
  ) -> HAPViewModel {
    let vm = HAPViewModel()
    vm.isRestoring = true
    vm.isRunning = running
    vm.isStarting = starting
    vm.hasPairings = paired
    vm.isLightOn = lightOn
    vm.brightness = brightness
    vm.flashlightEnabled = flashlightEnabled
    vm.motionEnabled = motionEnabled
    vm.isMotionDetected = motionDetected
    vm.isMotionAvailable = true
    vm.isCameraStreaming = cameraStreaming
    vm.ambientLux = ambientLux
    vm.screenSaverEnabled = screenSaverEnabled
    vm.screenSaverDelay = screenSaverDelay
    vm.keepScreenAwake = keepScreenAwake
    vm.setupCode = "123-45-678"
    vm.statusMessage = running ? "Advertising as 'Pylo Bridge'" : "Tap Start to begin"
    vm.selectedCamera = CameraOption(id: "preview-front", name: "Front Camera", fNumber: 2.2)
    vm.selectedStreamCamera = CameraOption(id: "preview-back", name: "Back Camera", fNumber: 1.8)
    vm.availableCameras = [
      CameraOption(id: "preview-front", name: "Front Camera", fNumber: 2.2),
      CameraOption(id: "preview-back", name: "Back Camera", fNumber: 1.8),
    ]
    vm.isRestoring = false
    if running {
      if needsRestart {
        // Snapshot with opposite flashlight to force needsRestart == true
        vm.startedConfig = AccessoryConfig(
          flashlightEnabled: !flashlightEnabled,
          cameraEnabled: vm.selectedStreamCamera != nil,
          lightSensorEnabled: vm.selectedCamera != nil,
          motionEnabled: motionEnabled
        )
      } else {
        vm.startedConfig = AccessoryConfig(from: vm)
      }
    }
    return vm
  }
}
