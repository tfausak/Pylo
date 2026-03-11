import SwiftUI

struct ContentView: View {
  @ObservedObject var viewModel: HAPViewModel
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      if viewModel.isNetworkDenied {
        networkDeniedBody
      } else if viewModel.hasPairings {
        if viewModel.isRunning {
          RunningView(viewModel: viewModel)
        } else {
          configBody
        }
      } else {
        PairingView(viewModel: viewModel)
      }
    }
    .onChange(of: scenePhase) { newPhase in
      if newPhase == .active {
        viewModel.recheckPermissions()
      } else if newPhase == .background {
        viewModel.handleBackgrounding()
      }
    }
  }

  // MARK: - Config Body (brief state while server starts)

  private var configBody: some View {
    NavigationView {
      ConfigCardsView(viewModel: viewModel)
        .navigationTitle("Pylo")
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            statusLabel(running: false)
          }
        }
    }
    .navigationViewStyle(.stack)
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

  // MARK: - Network Denied

  private var networkDeniedBody: some View {
    NavigationView {
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
      .navigationTitle("Pylo")
    }
    .navigationViewStyle(.stack)
  }

  static func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url)
    }
  }
}

// MARK: - Config Cards View

struct ConfigCardsView: View {
  @ObservedObject var viewModel: HAPViewModel
  @State private var showUnpairConfirmation = false

  var body: some View {
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

        // Doorbell
        AccessoryCard(
          icon: "bell.fill",
          title: "Doorbell",
          isOn: $viewModel.doorbellEnabled
        ) {
          doorbellContent
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
          blocked: !viewModel.hasCamera || viewModel.cameraPermissionDenied,
          blockedMessage: !viewModel.hasCamera
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
          isOn: $viewModel.motionEnabled,
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
          isOn: $viewModel.contactEnabled,
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

        // Keep Display On
        Toggle("Keep Display On", isOn: $viewModel.keepScreenAwake)
          .padding()
          .background(
            Color(UIColor.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12)
          )
      }
      .padding()
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
      Button("Open Settings") { ContentView.openSettings() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(viewModel.permissionAlert?.message ?? "")
    }
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        if viewModel.hasPairings {
          Menu {
            Button("Unpair", role: .destructive) {
              showUnpairConfirmation = true
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
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
  private var doorbellContent: some View {
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
  private var sirenContent: some View {
    HStack {
      Text("Status")
        .foregroundStyle(.secondary)
      Spacer()
      Text(viewModel.isSirenActive ? "Sounding" : "Off")
    }
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
      get: { viewModel.flashlightEnabled },
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
      get: { viewModel.lightSensorEnabled },
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
      get: { viewModel.occupancyEnabled },
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

#Preview("Pairing") {
  ContentView(viewModel: .preview(running: true))
}

#Preview("Paired") {
  ContentView(viewModel: .preview(running: true, paired: true, lightOn: true))
}

#Preview("Needs Restart") {
  ContentView(viewModel: .preview(running: true, paired: true, needsRestart: true))
}
