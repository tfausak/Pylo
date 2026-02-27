import SwiftUI

// MARK: - Accessory Configuration Section (shared by ConfigureView and SettingsView)

struct AccessoryConfigSection: View {
  @Bindable var viewModel: HAPViewModel

  var body: some View {
    Section("Accessories") {
      // Flashlight
      Toggle(isOn: $viewModel.flashlightEnabled) {
        Label("Flashlight", systemImage: "flashlight.off.fill")
      }

      // Motion Sensor
      Toggle(isOn: $viewModel.motionEnabled) {
        Label("Motion Sensor", systemImage: "figure.walk.motion")
      }

      // Ambient Light
      Toggle(isOn: lightSensorEnabled) {
        Label("Ambient Light", systemImage: "sun.max.fill")
      }
      if viewModel.selectedCamera != nil {
        Picker("Camera", selection: lightCameraBinding) {
          ForEach(viewModel.availableCameras) { camera in
            Text(camera.name).tag(camera)
          }
        }
      }

      // Camera
      Toggle(isOn: cameraEnabled) {
        Label("Camera", systemImage: "camera.fill")
      }
      if viewModel.selectedStreamCamera != nil {
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
  }

  /// Binding that maps selectedStreamCamera (optional) to a Bool toggle.
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

  /// Binding that maps selectedCamera (optional) to a Bool toggle.
  private var lightSensorEnabled: Binding<Bool> {
    Binding(
      get: { viewModel.selectedCamera != nil },
      set: { enabled in
        if enabled {
          viewModel.selectedCamera =
            viewModel.availableCameras.first { $0.name.localizedCaseInsensitiveContains("front") }
            ?? viewModel.availableCameras.first
        } else {
          viewModel.selectedCamera = nil
        }
      }
    )
  }

  /// Non-optional binding for the stream camera picker (only used when non-nil).
  private var streamCameraBinding: Binding<CameraOption> {
    Binding(
      get: { viewModel.selectedStreamCamera ?? viewModel.availableCameras[0] },
      set: { viewModel.selectedStreamCamera = $0 }
    )
  }

  /// Non-optional binding for the light sensor camera picker (only used when non-nil).
  private var lightCameraBinding: Binding<CameraOption> {
    Binding(
      get: { viewModel.selectedCamera ?? viewModel.availableCameras[0] },
      set: { viewModel.selectedCamera = $0 }
    )
  }
}

// MARK: - Configure View

struct ConfigureView: View {
  @Bindable var viewModel: HAPViewModel
  @State private var showResetConfirmation = false

  var body: some View {
    VStack(spacing: 0) {
      Form {
        AccessoryConfigSection(viewModel: viewModel)

        Section("General") {
          Toggle("Keep Screen Awake", isOn: $viewModel.keepScreenAwake)
          if viewModel.keepScreenAwake {
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

        if viewModel.hasPairings {
          Section {
            Button("Reset Pairings", role: .destructive) {
              showResetConfirmation = true
            }
          }
        }
      }
      .confirmationDialog(
        "Reset Pairings",
        isPresented: $showResetConfirmation,
        titleVisibility: .visible
      ) {
        Button("Reset Pairings", role: .destructive) {
          viewModel.resetPairings()
        }
      } message: {
        Text(
          "This will remove all HomeKit pairings. You will need to re-add this bridge in the Home app."
        )
      }

      Button(action: { viewModel.start() }) {
        Group {
          if viewModel.isStarting {
            HStack(spacing: 8) {
              ProgressView()
                .tint(.white)
              Text("Starting…")
            }
          } else {
            Text("Start Server")
          }
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding()
        .background(viewModel.isStarting ? Color.gray : Color.blue)
        .foregroundStyle(.white)
        .clipShape(.rect(cornerRadius: 12))
      }
      .disabled(viewModel.isStarting)
      .padding()
    }
  }
}

#Preview("Configure") {
  NavigationStack {
    ConfigureView(viewModel: .preview())
      .navigationTitle("Pylo")
  }
}
