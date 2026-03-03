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
  private var displayContent: some View {
    VStack(spacing: 12) {
      Toggle("Screen Saver", isOn: $viewModel.screenSaverEnabled)
      if viewModel.screenSaverEnabled {
        HStack {
          Text("Delay")
            .foregroundStyle(.secondary)
          Spacer()
          Picker("Delay", selection: $viewModel.screenSaverDelay) {
            Text("1 min").tag(TimeInterval(60))
            Text("2 min").tag(TimeInterval(120))
            Text("5 min").tag(TimeInterval(300))
            Text("10 min").tag(TimeInterval(600))
          }
          .labelsHidden()
          .pickerStyle(.menu)
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
