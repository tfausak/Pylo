import SwiftUI

struct ContentView: View {
  @ObservedObject var viewModel: HAPViewModel
  var forceConfig = false
  @Environment(\.scenePhase) private var scenePhase
  @State private var showUnpairConfirmation = false

  var body: some View {
    ZStack {
      navigationContainer {
        Group {
          if viewModel.isNetworkDenied {
            networkDeniedBody
          } else if viewModel.hasPairings {
            if viewModel.isRunning && !forceConfig {
              RunningView(viewModel: viewModel)
            } else {
              pairedBody
            }
          } else {
            PairingView(viewModel: viewModel)
          }
        }
        .navigationTitle("Pylo")
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            statusIndicator
          }
        }
        .safeAreaInset(edge: .bottom) {
          if viewModel.needsRestart {
            Text("Restart to Apply")
              .font(.subheadline.weight(.medium))
              .frame(maxWidth: .infinity)
              .padding(12)
              .background(.orange, in: .rect(cornerRadius: 12))
              .foregroundStyle(.white)
              .contentShape(Rectangle())
              .onTapGesture {
                viewModel.restart()
              }
              .accessibilityAddTraits(.isButton)
              .padding(.horizontal)
              .padding(.bottom, 4)
              .transition(.move(edge: .bottom).combined(with: .opacity))
          } else if viewModel.isWaitingForHomeApp {
            HStack(spacing: 8) {
              ProgressView()
              Text("Updating Home…")
                .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(.secondary.opacity(0.2), in: .rect(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
          }
        }
        .animation(.default, value: viewModel.needsRestart)
        .animation(.default, value: viewModel.isWaitingForHomeApp)
      }
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
      .alert(
        viewModel.permissionAlert?.title ?? "",
        isPresented: permissionAlertPresented
      ) {
        Button("Open Settings") { Self.openSettings() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(viewModel.permissionAlert?.message ?? "")
      }

    }
    .onChangeCompat(of: scenePhase) { newPhase in
      if newPhase == .active {
        viewModel.recheckPermissions()
      } else if newPhase == .background {
        viewModel.handleBackgrounding()
      }
    }
  }

  // MARK: - Status Indicator

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
        .accessibilityHidden(true)
      Text(running ? "Running" : viewModel.isStarting ? "Starting" : "Stopped")
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
          isOn: cameraEnabled,
          blocked: !viewModel.hasCamera || viewModel.cameraPermissionDenied,
          blockedMessage: !viewModel.hasCamera
            ? "Not available on this device"
            : viewModel.cameraPermissionDenied ? "Permission denied" : nil
        ) {
          cameraContent
        }

        // Button
        AccessoryCard(
          icon: "button.horizontal.top.press.fill",
          title: "Button",
          isOn: $viewModel.buttonEnabled
        ) {
          buttonContent
        }

        // Flashlight
        AccessoryCard(
          icon: "flashlight.off.fill",
          title: "Flashlight",
          isOn: flashlightEnabled,
          blocked: !viewModel.hasTorch || viewModel.cameraPermissionDenied,
          blockedMessage: !viewModel.hasTorch
            ? "Not available on this device"
            : viewModel.cameraPermissionDenied ? "Permission denied" : nil
        ) {
          flashlightContent
        }

        // Light Sensor
        AccessoryCard(
          icon: "light.beacon.max",
          title: "Light Sensor",
          isOn: lightSensorEnabled,
          blocked: !viewModel.hasCamera || !viewModel.hasAmbientLight
            || viewModel.cameraPermissionDenied,
          blockedMessage: !viewModel.hasCamera || !viewModel.hasAmbientLight
            ? "Not available on this device"
            : viewModel.cameraPermissionDenied ? "Permission denied" : nil
        ) {
          lightSensorContent
        }

        // Occupancy Sensor
        AccessoryCard(
          icon: "person.fill.viewfinder",
          title: "Occupancy Sensor",
          isOn: occupancyEnabled,
          blocked: !viewModel.hasCamera || viewModel.cameraPermissionDenied,
          blockedMessage: !viewModel.hasCamera
            ? "Not available on this device"
            : viewModel.cameraPermissionDenied ? "Permission denied" : nil
        ) {
          occupancyContent
        }

        // Motion Sensor
        AccessoryCard(
          icon: "figure.walk.motion",
          title: "Motion Sensor",
          isOn: motionEnabled,
          blocked: !viewModel.hasAccelerometer,
          blockedMessage: !viewModel.hasAccelerometer
            ? "Not available on this device" : nil
        ) {
          motionContent
        }

        // Contact Sensor
        AccessoryCard(
          icon: "sensor.tag.radiowaves.forward.fill",
          title: "Contact Sensor",
          isOn: contactEnabled,
          blocked: !viewModel.hasProximity,
          blockedMessage: !viewModel.hasProximity
            ? "Not available on this device" : nil
        ) {
          contactContent
        }

        // Siren
        AccessoryCard(
          icon: "speaker.wave.3.fill",
          title: "Siren",
          isOn: $viewModel.sirenEnabled
        ) {
          sirenContent
        }

        // Button
        AccessoryCard(
          icon: "bell.fill",
          title: "Button",
          isOn: $viewModel.buttonEnabled
        ) {
          Text("Stateless programmable switch. Trigger from the running screen; configure automations in Home.app.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // Display / Sleep
        #if os(iOS)
          AccessoryCard(
            icon: "display",
            title: "Keep Display On",
            isOn: $viewModel.keepScreenAwake
          ) {
            displayContent
          }
        #else
          AccessoryCard(
            icon: "moon.zzz",
            title: "Prevent Sleep",
            isOn: $viewModel.keepScreenAwake
          ) {}
        #endif
      }
      .padding()
    }
  }

  // MARK: - Network Denied

  private var networkDeniedBody: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "wifi.exclamationmark")
        .font(.system(size: 56))
        .foregroundStyle(.secondary)
      Text("Local Network Access Required")
        .font(.title3.weight(.semibold))
      Text(
        "Pylo needs local network access to communicate with the Home app. Enable it in Settings."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      Button("Open Settings") { Self.openSettings() }
        .buttonStyle(.borderedProminent)
      Spacer()
    }
    .padding()
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
      HStack {
        Text("Camera")
          .foregroundStyle(.secondary)
        Spacer()
        Picker("Camera", selection: streamCameraBinding) {
          ForEach(viewModel.availableCameras) { camera in
            Text(camera.name).tag(camera)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
      HStack {
        Text("Quality")
          .foregroundStyle(.secondary)
        Spacer()
        Picker("Quality", selection: $viewModel.videoQuality) {
          ForEach(VideoQuality.allCases) { quality in
            Text(quality.rawValue).tag(quality)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
      Toggle("Microphone", isOn: microphoneEnabled)
        .tint(viewModel.microphonePermissionDenied ? Color.secondary : nil)
        .disabled(viewModel.microphonePermissionDenied)
    }
  }

  @ViewBuilder
  private var buttonContent: some View {
    HStack {
      Text("Status")
        .foregroundStyle(.secondary)
      Spacer()
      Text("Ready")
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
  private var lightSensorContent: some View {
    VStack(spacing: 12) {
      if viewModel.selectedStreamCamera != nil {
        HStack {
          Text("Camera")
            .foregroundStyle(.secondary)
          Spacer()
          Text(viewModel.selectedStreamCamera?.name ?? "")
        }
      } else {
        sensorCameraPicker
      }
    }
  }

  @ViewBuilder
  private var occupancyContent: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Status")
          .foregroundStyle(.secondary)
        Spacer()
        Text(viewModel.isOccupancyDetected ? "Occupied" : "Unoccupied")
      }
      HStack {
        Text("Cooldown")
          .foregroundStyle(.secondary)
        Spacer()
        Picker("Cooldown", selection: $viewModel.occupancyCooldown) {
          ForEach(OccupancyCooldown.allCases) { cooldown in
            Text(cooldown.rawValue).tag(cooldown)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
      if viewModel.selectedStreamCamera != nil {
        HStack {
          Text("Camera")
            .foregroundStyle(.secondary)
          Spacer()
          Text(viewModel.selectedStreamCamera?.name ?? "")
        }
      } else {
        sensorCameraPicker
      }
    }
  }

  @ViewBuilder
  private var sensorCameraPicker: some View {
    HStack {
      Text("Camera")
        .foregroundStyle(.secondary)
      Spacer()
      Picker("Camera", selection: sensorCameraBinding) {
        ForEach(viewModel.availableCameras) { camera in
          Text(camera.name).tag(camera)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
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
      HStack {
        Text("Sensitivity")
          .foregroundStyle(.secondary)
        Spacer()
        Picker("Sensitivity", selection: $viewModel.motionSensitivity) {
          ForEach(MotionSensitivity.allCases) { sensitivity in
            Text(sensitivity.rawValue).tag(sensitivity)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
    }
  }

  @ViewBuilder
  private var contactContent: some View {
    HStack {
      Text("Status")
        .foregroundStyle(.secondary)
      Spacer()
      Text(viewModel.isContactDetected ? "Closed" : "Open")
    }
  }

  @ViewBuilder
  private var displayContent: some View {
    EmptyView()
  }

  @ViewBuilder
  private var sirenContent: some View {
    HStack {
      Text("Status")
        .foregroundStyle(.secondary)
      Spacer()
      Text(viewModel.isSirenActive ? "Sounding" : "Off")
    }
  }

  private static func openSettings() {
    openAppSettings()
  }

  // MARK: - Bindings

  private var permissionAlertPresented: Binding<Bool> {
    Binding(
      get: { viewModel.permissionAlert != nil },
      set: { if !$0 { viewModel.permissionAlert = nil } }
    )
  }

  private var cameraEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.selectedStreamCamera != nil },
      set: { enabled in
        if enabled {
          Task {
            guard await viewModel.requestCameraPermission() else {
              viewModel.permissionAlert = .camera
              return
            }
            viewModel.selectedStreamCamera =
              viewModel.availableCameras.first {
                $0.name.localizedCaseInsensitiveContains("back")
              }
              ?? viewModel.availableCameras.first
          }
        } else {
          viewModel.selectedStreamCamera = nil
        }
      }
    )
  }

  private var flashlightEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.flashlightEnabled && viewModel.hasTorch },
      set: { enabled in
        if enabled {
          Task {
            guard await viewModel.requestCameraPermission() else {
              viewModel.permissionAlert = .camera
              return
            }
            viewModel.flashlightEnabled = true
          }
        } else {
          viewModel.flashlightEnabled = false
        }
      }
    )
  }

  private var microphoneEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.microphoneEnabled },
      set: { enabled in
        if enabled {
          Task {
            guard await viewModel.requestMicrophonePermission() else {
              viewModel.permissionAlert = .microphone
              return
            }
            viewModel.microphoneEnabled = true
          }
        } else {
          viewModel.microphoneEnabled = false
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

  private var lightSensorEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.lightSensorEnabled && viewModel.hasAmbientLight },
      set: { enabled in
        if enabled {
          Task {
            guard await viewModel.requestCameraPermission() else {
              viewModel.permissionAlert = .camera
              return
            }
            viewModel.lightSensorEnabled = true
            ensureSensorCamera()
          }
        } else {
          viewModel.lightSensorEnabled = false
        }
      }
    )
  }

  private var occupancyEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.occupancyEnabled && viewModel.hasCamera },
      set: { enabled in
        if enabled {
          Task {
            guard await viewModel.requestCameraPermission() else {
              viewModel.permissionAlert = .camera
              return
            }
            viewModel.occupancyEnabled = true
            ensureSensorCamera()
          }
        } else {
          viewModel.occupancyEnabled = false
        }
      }
    )
  }

  private var motionEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.motionEnabled && viewModel.hasAccelerometer },
      set: { viewModel.motionEnabled = $0 }
    )
  }

  private var contactEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.contactEnabled && viewModel.hasProximity },
      set: { viewModel.contactEnabled = $0 }
    )
  }

  private var sensorCameraBinding: Binding<CameraOption> {
    Binding(
      get: {
        viewModel.sensorCamera ?? viewModel.availableCameras.first
          ?? CameraOption(id: "", name: "None", fNumber: 0)
      },
      set: { viewModel.sensorCamera = $0 }
    )
  }

  /// Ensures a sensor camera is selected when enabling a sensor without the camera accessory.
  private func ensureSensorCamera() {
    guard viewModel.selectedStreamCamera == nil, viewModel.sensorCamera == nil else { return }
    viewModel.sensorCamera =
      viewModel.availableCameras.first {
        $0.name.localizedCaseInsensitiveContains("back")
      }
      ?? viewModel.availableCameras.first
  }

}

// MARK: - Compatibility Helpers

/// Wraps content in NavigationStack (iOS 16+/macOS 13+) or NavigationView+stack (older).
private struct NavigationContainer<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    #if os(iOS)
      if #available(iOS 16.0, *) {
        NavigationStack(root: content)
      } else {
        NavigationView(content: content)
          .navigationViewStyle(.stack)
      }
    #else
      if #available(macOS 13.0, *) {
        NavigationStack(root: content)
      } else {
        NavigationView(content: content)
      }
    #endif
  }
}

private func navigationContainer<Content: View>(
  @ViewBuilder content: @escaping () -> Content
) -> NavigationContainer<Content> {
  NavigationContainer(content: content)
}

extension View {
  /// onChange that compiles on both iOS 15 and iOS 17+/macOS 14+.
  @ViewBuilder
  func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View
  {
    if #available(iOS 17.0, macOS 14.0, *) {
      self.onChange(of: value) { _, newValue in action(newValue) }
    } else {
      self.onChange(of: value, perform: action)
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
