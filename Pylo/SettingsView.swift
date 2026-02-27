import SwiftUI

struct SettingsView: View {
  @Bindable var viewModel: HAPViewModel
  @State private var showResetConfirmation = false

  var body: some View {
    Form {
      AccessoryConfigSection(viewModel: viewModel)

      if viewModel.needsRestart {
        Section {
          Button("Restart Server") {
            viewModel.restart()
          }
          .fontWeight(.semibold)
          .frame(maxWidth: .infinity)
        } footer: {
          Text("Configuration changes require a server restart.")
        }
      }

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

      Section {
        Button("Stop Server") {
          viewModel.stop()
        }
        .foregroundStyle(.orange)
        if viewModel.hasPairings {
          Button("Reset Pairings", role: .destructive) {
            showResetConfirmation = true
          }
        }
      }
    }
    .navigationTitle("Settings")
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
  }
}

#Preview("Settings") {
  NavigationStack {
    SettingsView(viewModel: .preview(running: true, paired: true))
  }
}

#Preview("Settings - Needs Restart") {
  NavigationStack {
    SettingsView(viewModel: .preview(running: true, paired: true, needsRestart: true))
  }
}
