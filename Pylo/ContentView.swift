import SwiftUI

struct ContentView: View {
  @ObservedObject var viewModel: HAPViewModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var showUnpairConfirmation = false
  @State private var isScreenDimmed = false
  @State private var dimTask: Task<Void, Never>?
  @State private var isDimTimerResetPending = false

  var body: some View {
    ZStack {
      NavigationView {
        Group {
          if viewModel.isNetworkDenied {
            networkDeniedBody
          } else if viewModel.hasPairings {
            pairedBody
          } else {
            PairingView(viewModel: viewModel)
          }
        }
        .navigationTitle("Pylo")
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            statusIndicator
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
      .navigationViewStyle(.stack)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard !isDimTimerResetPending else { return }
            isDimTimerResetPending = true
            resetDimTimer()
          }
          .onEnded { _ in isDimTimerResetPending = false }
      )
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

      if isScreenDimmed {
        Color.black
          .ignoresSafeArea()
          .accessibilityLabel("Screen dimmed")
          .accessibilityHint("Tap to wake")
          .accessibilityAddTraits(.isButton)
          .onTapGesture { resetDimTimer() }
      }
    }
    .animation(.default, value: isScreenDimmed)
    .onChange(of: viewModel.isRunning) { _ in
      if viewModel.isRunning {
        resetDimTimer()
      } else {
        dimTask?.cancel()
        dimTask = nil
        isScreenDimmed = false
      }
    }
    .onChange(of: viewModel.keepScreenAwake) { _ in
      resetDimTimer()
    }
    .onChange(of: viewModel.screenSaverEnabled) { _ in
      if viewModel.isRunning { resetDimTimer() }
    }
    .onChange(of: viewModel.screenSaverDelay) { _ in
      if viewModel.isRunning { resetDimTimer() }
    }
    .onChange(of: scenePhase) { _ in
      if scenePhase == .active {
        viewModel.recheckPermissions()
      }
    }
    .onChange(of: viewModel.hasPairings) { _ in
      if !viewModel.hasPairings {
        dimTask?.cancel()
        dimTask = nil
        isScreenDimmed = false
      } else if viewModel.isRunning {
        resetDimTimer()
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
          isOn: cameraEnabled,
          blocked: !viewModel.hasCamera || viewModel.cameraPermissionDenied,
          blockedMessage: !viewModel.hasCamera
            ? "Not available on this device"
            : viewModel.cameraPermissionDenied ? "Permission denied" : nil
        ) {
          cameraContent
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

  private static func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url)
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

  // MARK: - Screen Dimming

  private func resetDimTimer() {
    dimTask?.cancel()
    isScreenDimmed = false
    guard viewModel.isRunning, viewModel.hasPairings, viewModel.keepScreenAwake,
      viewModel.screenSaverEnabled
    else {
      return
    }
    dimTask = Task {
      // Task.sleep throws CancellationError when the task is cancelled,
      // cleanly preventing the stale isScreenDimmed write.
      let delaySeconds = viewModel.screenSaverDelay
      guard delaySeconds.isFinite, delaySeconds > 0 else { return }
      guard
        (try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000)))
          != nil
      else {
        return
      }
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
