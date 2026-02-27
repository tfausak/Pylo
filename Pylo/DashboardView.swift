import SwiftUI

struct DashboardView: View {
  var viewModel: HAPViewModel

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        VStack(spacing: 4) {
          Text("Pylo Bridge")
            .font(.title2)
            .fontWeight(.bold)
          HStack(spacing: 4) {
            Circle()
              .fill(.green)
              .frame(width: 8, height: 8)
              .accessibilityHidden(true)
            Text("Running")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.bottom, 8)

        if viewModel.flashlightEnabled {
          StatusCard(
            icon: viewModel.isLightOn ? "flashlight.on.fill" : "flashlight.off.fill",
            iconColor: viewModel.isLightOn ? .yellow : .gray,
            title: "Flashlight",
            value: viewModel.isLightOn
              ? "On\(viewModel.brightness < 100 ? " · \(viewModel.brightness)%" : "")" : "Off"
          )
        }

        if viewModel.motionEnabled {
          StatusCard(
            icon: viewModel.isMotionDetected ? "figure.walk.motion" : "figure.stand",
            iconColor: viewModel.isMotionDetected ? .blue : .gray,
            title: "Motion",
            value: viewModel.isMotionDetected ? "Motion Detected" : "No Motion"
          )
        }

        if viewModel.selectedCamera != nil {
          StatusCard(
            icon: "sun.max.fill",
            iconColor: .orange,
            title: "Light",
            value: String(format: "%.1f lux", viewModel.ambientLux)
          )
        }

        if viewModel.selectedStreamCamera != nil {
          StatusCard(
            icon: viewModel.isCameraStreaming ? "video.fill" : "video",
            iconColor: viewModel.isCameraStreaming ? .green : .gray,
            title: "Camera",
            value: viewModel.isCameraStreaming ? "Streaming" : "Idle"
          )
        }

      }
      .padding()
    }
  }
}

// MARK: - Status Card

private struct StatusCard: View {
  let icon: String
  let iconColor: Color
  let title: String
  let value: String

  var body: some View {
    HStack {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(iconColor)
        .frame(width: 32)
      Text(title)
        .font(.body)
      Spacer()
      Text(value)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding()
    .background(.quaternary, in: .rect(cornerRadius: 12))
  }
}

#Preview("Dashboard") {
  NavigationStack {
    DashboardView(viewModel: .preview(running: true, paired: true, lightOn: true))
      .navigationTitle("Pylo")
  }
}

#Preview("Dashboard - Streaming") {
  NavigationStack {
    DashboardView(
      viewModel: .preview(running: true, paired: true, cameraStreaming: true, ambientLux: 350.0)
    )
    .navigationTitle("Pylo")
  }
}
