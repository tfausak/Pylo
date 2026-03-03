# Unified UI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the multi-screen UI with a single unified screen featuring auto-start, accessory widget cards with expand/collapse toggles, and inline editing.

**Architecture:** Two app states — unpaired (full-screen QR/setup code) and paired (scrollable accessory card list). Server auto-starts on launch. All configuration is inline within expandable cards. Status menu in header provides unpair action.

**Tech Stack:** SwiftUI, @Observable, @Bindable

---

### Task 1: Make server auto-start on launch

**Files:**
- Modify: `Pylo/HAPViewModel.swift:184-186` (remove `hasStartedBefore` guard in `restorePreferences()`)

**Step 1: Remove the conditional start guard**

In `HAPViewModel.swift`, the `restorePreferences()` method currently only calls `start()` if the user has started before. Change it to always start:

```swift
// In restorePreferences(), replace lines 184-186:
// OLD:
    if UserDefaults.standard.bool(forKey: "hasStartedBefore") {
      start()
    }

// NEW:
    start()
```

**Step 2: Remove the `hasStartedBefore` write in `start()`**

In `HAPViewModel.swift`, delete line 352:
```swift
// DELETE this line from start():
      UserDefaults.standard.set(true, forKey: "hasStartedBefore")
```

**Step 3: Build and verify**

Run: `./scripts/build.sh`
Expected: Clean build (or only the `IDERunDestination` warning)

**Step 4: Commit**

```bash
git add Pylo/HAPViewModel.swift
git commit -m "Auto-start server on launch"
```

---

### Task 2: Create AccessoryCard component

**Files:**
- Create: `Pylo/AccessoryCard.swift`

**Step 1: Create the AccessoryCard view**

Create `Pylo/AccessoryCard.swift` with this content:

```swift
import SwiftUI

struct AccessoryCard<Content: View>: View {
  let icon: String
  let title: String
  @Binding var isOn: Bool
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      // Header row: icon, title, toggle
      HStack {
        Image(systemName: icon)
          .font(.title3)
          .foregroundStyle(isOn ? .accent : .secondary)
          .frame(width: 28)
        Text(title)
          .font(.headline)
        Spacer()
        Toggle("", isOn: $isOn)
          .labelsHidden()
      }
      .padding()

      // Expanded content when toggle is on
      if isOn {
        Divider()
          .padding(.horizontal)
        content()
          .padding()
      }
    }
    .background(.quaternary, in: .rect(cornerRadius: 12))
    .animation(.default, value: isOn)
  }
}
```

**Step 2: Build and verify**

Run: `./scripts/build.sh`
Expected: Clean build

**Step 3: Commit**

```bash
git add Pylo/AccessoryCard.swift
git commit -m "Add AccessoryCard expand/collapse component"
```

---

### Task 3: Rewrite ContentView with unified layout

**Files:**
- Rewrite: `Pylo/ContentView.swift`

**Step 1: Rewrite ContentView**

Replace `Pylo/ContentView.swift` entirely. The new ContentView has two states:
- Unpaired: shows PairingView
- Paired: shows scrollable list of AccessoryCards

```swift
import SwiftUI

struct ContentView: View {
  @Bindable var viewModel: HAPViewModel
  @State private var showUnpairConfirmation = false
  @State private var isScreenDimmed = false
  @State private var dimTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        header
          .padding(.horizontal)
          .padding(.top, 8)

        if viewModel.hasPairings {
          pairedBody
        } else {
          PairingView(viewModel: viewModel)
        }
      }
      .safeAreaInset(edge: .bottom) {
        if viewModel.needsRestart {
          Button {
            viewModel.restart()
          } label: {
            Text("Restart to Apply")
              .font(.subheadline.weight(.medium))
              .frame(maxWidth: .infinity)
              .padding(12)
              .background(.orange, in: .rect(cornerRadius: 12))
              .foregroundStyle(.white)
          }
          .padding(.horizontal)
          .padding(.bottom, 4)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.default, value: viewModel.needsRestart)
      .confirmationDialog(
        "Unpair",
        isPresented: $showUnpairConfirmation,
        titleVisibility: .visible
      ) {
        Button("Unpair", role: .destructive) {
          viewModel.resetPairings()
        }
      } message: {
        Text(
          "This will remove all HomeKit pairings. You will need to re-add this bridge in the Home app."
        )
      }

      if isScreenDimmed {
        Color.black
          .ignoresSafeArea()
          .onTapGesture { resetDimTimer() }
      }
    }
    .animation(.default, value: isScreenDimmed)
    .onChange(of: viewModel.isRunning) {
      if viewModel.isRunning {
        resetDimTimer()
      } else {
        dimTask?.cancel()
        dimTask = nil
        isScreenDimmed = false
      }
    }
    .onChange(of: viewModel.keepScreenAwake) {
      if viewModel.isRunning { resetDimTimer() }
    }
    .onChange(of: viewModel.screenSaverEnabled) {
      if viewModel.isRunning { resetDimTimer() }
    }
    .onChange(of: viewModel.screenSaverDelay) {
      if viewModel.isRunning { resetDimTimer() }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("Pylo")
        .font(.largeTitle)
        .fontWeight(.bold)
      Spacer()
      statusIndicator
    }
  }

  @ViewBuilder
  private var statusIndicator: some View {
    let isRunning = viewModel.isRunning

    if viewModel.hasPairings {
      Menu {
        Button("Unpair", role: .destructive) {
          showUnpairConfirmation = true
        }
      } label: {
        statusLabel(running: isRunning)
      }
    } else {
      statusLabel(running: isRunning)
    }
  }

  private func statusLabel(running: Bool) -> some View {
    HStack(spacing: 6) {
      Image(systemName: running ? "checkmark.circle.fill" : "bolt.fill")
        .foregroundStyle(running ? .green : .orange)
      Text(running ? "Running" : "Starting")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Paired Body

  private var pairedBody: some View {
    ScrollView {
      VStack(spacing: 12) {
        // Camera
        AccessoryCard(
          icon: "camera.fill",
          title: "Camera",
          isOn: cameraEnabled
        ) {
          cameraContent
        }

        // Flashlight
        AccessoryCard(
          icon: "flashlight.off.fill",
          title: "Flashlight",
          isOn: $viewModel.flashlightEnabled
        ) {
          flashlightContent
        }

        // Motion Sensor
        AccessoryCard(
          icon: "figure.walk.motion",
          title: "Motion Sensor",
          isOn: $viewModel.motionEnabled
        ) {
          motionContent
        }

        // Display
        AccessoryCard(
          icon: "display",
          title: "Display",
          isOn: $viewModel.keepScreenAwake
        ) {
          displayContent
        }
      }
      .padding()
    }
  }

  // MARK: - Card Contents

  @ViewBuilder
  private var cameraContent: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Status")
          .foregroundStyle(.secondary)
        Spacer()
        Text(viewModel.isCameraStreaming ? "Streaming" : "Idle")
      }
      Picker("Camera", selection: streamCameraBinding) {
        ForEach(viewModel.availableCameras) { camera in
          Text(camera.name).tag(camera)
        }
      }
      Picker("Quality", selection: $viewModel.videoQuality) {
        ForEach(VideoQuality.allCases) { quality in
          Text(quality.rawValue).tag(quality)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  @ViewBuilder
  private var flashlightContent: some View {
    HStack {
      Text("Status")
        .foregroundStyle(.secondary)
      Spacer()
      Text(
        viewModel.isLightOn
          ? "On\(viewModel.brightness < 100 ? " · \(viewModel.brightness)%" : "")"
          : "Off"
      )
    }
  }

  @ViewBuilder
  private var motionContent: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Status")
          .foregroundStyle(.secondary)
        Spacer()
        Text(viewModel.isMotionDetected ? "Motion Detected" : "No Motion")
      }
      Picker("Sensitivity", selection: $viewModel.motionSensitivity) {
        ForEach(MotionSensitivity.allCases) { sensitivity in
          Text(sensitivity.rawValue).tag(sensitivity)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  @ViewBuilder
  private var displayContent: some View {
    VStack(spacing: 12) {
      Toggle("Screen Saver", isOn: $viewModel.screenSaverEnabled)
      if viewModel.screenSaverEnabled {
        Picker("Delay", selection: $viewModel.screenSaverDelay) {
          Text("1 min").tag(TimeInterval(60))
          Text("2 min").tag(TimeInterval(120))
          Text("5 min").tag(TimeInterval(300))
          Text("10 min").tag(TimeInterval(600))
        }
      }
    }
  }

  // MARK: - Bindings

  private var cameraEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.selectedStreamCamera != nil },
      set: { enabled in
        if enabled {
          viewModel.selectedStreamCamera =
            viewModel.availableCameras.first { $0.name.localizedCaseInsensitiveContains("back") }
            ?? viewModel.availableCameras.first
        } else {
          viewModel.selectedStreamCamera = nil
        }
      }
    )
  }

  private var streamCameraBinding: Binding<CameraOption> {
    Binding(
      get: {
        viewModel.selectedStreamCamera ?? viewModel.availableCameras.first
          ?? CameraOption(id: "", name: "None", fNumber: 0)
      },
      set: { viewModel.selectedStreamCamera = $0 }
    )
  }

  // MARK: - Screen Dimming

  private func resetDimTimer() {
    dimTask?.cancel()
    isScreenDimmed = false
    guard viewModel.isRunning, viewModel.keepScreenAwake, viewModel.screenSaverEnabled else {
      return
    }
    dimTask = Task {
      try? await Task.sleep(for: .seconds(viewModel.screenSaverDelay))
      guard !Task.isCancelled else { return }
      isScreenDimmed = true
    }
  }
}

#Preview("Pairing") {
  ContentView(viewModel: .preview(running: true))
}

#Preview("Paired") {
  ContentView(viewModel: .preview(running: true, paired: true, lightOn: true))
}

#Preview("Needs Restart") {
  ContentView(viewModel: .preview(running: true, paired: true, needsRestart: true))
}
```

**Step 2: Build and verify**

Run: `./scripts/build.sh`
Expected: Build succeeds. (ConfigureView, SettingsView, DashboardView still exist but are now unused.)

**Step 3: Commit**

```bash
git add Pylo/ContentView.swift
git commit -m "Rewrite ContentView with unified accessory card layout"
```

---

### Task 4: Update PairingView to remove redundant status elements

**Files:**
- Modify: `Pylo/PairingView.swift`

**Step 1: Simplify PairingView**

The header with status is now in ContentView, so PairingView just needs the QR code, setup code, and instruction text. Remove the bottom status indicator and status message. Replace the entire file:

```swift
import SwiftUI

struct PairingView: View {
  var viewModel: HAPViewModel
  @State private var qrImage: UIImage?

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      if let qr = qrImage {
        Image(uiImage: qr)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 200, height: 200)
      } else {
        RoundedRectangle(cornerRadius: 12)
          .fill(.quaternary)
          .frame(width: 200, height: 200)
      }

      Text(viewModel.setupCode)
        .font(.system(.largeTitle, design: .monospaced))
        .fontWeight(.bold)

      Text("Scan with the Home app\nor enter the code manually")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Spacer()
    }
    .padding()
    .task(id: viewModel.setupCode) {
      let code = viewModel.setupCode
      let image = await Task.detached {
        await generateQRCode(from: hapSetupURI(setupCode: code))
      }.value
      qrImage = image
    }
  }
}

#Preview("Pairing") {
  PairingView(viewModel: .preview(running: true))
}
```

**Step 2: Build and verify**

Run: `./scripts/build.sh`
Expected: Clean build

**Step 3: Commit**

```bash
git add Pylo/PairingView.swift
git commit -m "Simplify PairingView — status now shown in ContentView header"
```

---

### Task 5: Delete old views and clean up

**Files:**
- Delete: `Pylo/ConfigureView.swift`
- Delete: `Pylo/SettingsView.swift`
- Delete: `Pylo/DashboardView.swift`
- Modify: `Pylo/PreviewHelpers.swift` (remove `starting` parameter, update `statusMessage` default)

**Step 1: Delete the old view files**

```bash
git rm Pylo/ConfigureView.swift Pylo/SettingsView.swift Pylo/DashboardView.swift
```

**Step 2: Update PreviewHelpers**

In `Pylo/PreviewHelpers.swift`, remove the `starting` parameter and update the `statusMessage`:

```swift
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
    let vm = HAPViewModel()
    vm.isRestoring = true
    vm.isRunning = running
    vm.hasPairings = paired
    vm.isLightOn = lightOn
    vm.brightness = brightness
    vm.flashlightEnabled = flashlightEnabled
    vm.motionEnabled = motionEnabled
    vm.isMotionDetected = motionDetected
    vm.isMotionAvailable = true
    vm.isCameraStreaming = cameraStreaming
    vm.screenSaverEnabled = screenSaverEnabled
    vm.screenSaverDelay = screenSaverDelay
    vm.keepScreenAwake = keepScreenAwake
    vm.setupCode = "123-45-678"
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
          motionEnabled: motionEnabled
        )
      } else {
        vm.startedConfig = AccessoryConfig(from: vm)
      }
    }
    return vm
  }
}
```

**Step 3: Build and verify**

Run: `./scripts/build.sh`
Expected: Clean build. No references to deleted views remain.

**Step 4: Commit**

```bash
git add -A
git commit -m "Delete ConfigureView, SettingsView, DashboardView; clean up previews"
```

---

### Task 6: Remove Xcode project references to deleted files

**Files:**
- Modify: Xcode project file (if files are referenced there — may need to check)

**Step 1: Check if build passes after file deletion**

Run: `./scripts/build.sh`

If the build fails because Xcode still references deleted files, the project file needs updating. If it builds clean (SPM-style or folder references), this task is done.

**Step 2: Fix any remaining references**

If there are compile errors from references to `AccessoryConfigSection` (defined in the deleted `ConfigureView.swift`), those are already replaced by the inline card contents in ContentView. If there are project file references, remove them.

**Step 3: Run format and lint**

```bash
./scripts/format.sh
./scripts/lint.sh
```

**Step 4: Build final verification**

Run: `./scripts/build.sh`
Expected: Clean build

**Step 5: Commit any fixups**

```bash
git add -A
git commit -m "Fix remaining references after view cleanup"
```
