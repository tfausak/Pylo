import SwiftUI

struct ContentView: View {
  @Bindable var viewModel: HAPViewModel
  @State private var showSettings = false
  @State private var isScreenDimmed = false
  @State private var dimTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      NavigationStack {
        Group {
          if viewModel.isRunning || viewModel.isStarting {
            if viewModel.hasPairings {
              DashboardView(viewModel: viewModel)
            } else {
              PairingView(viewModel: viewModel)
            }
          } else {
            ConfigureView(viewModel: viewModel)
          }
        }
        .navigationTitle("Pylo")
        .toolbar {
          if viewModel.isRunning {
            ToolbarItem(placement: .topBarLeading) {
              Button {
                showSettings = true
              } label: {
                Image(systemName: "gearshape")
              }
            }
          }
        }
        .safeAreaInset(edge: .bottom) {
          if viewModel.isRunning && viewModel.needsRestart {
            Button {
              viewModel.restart()
            } label: {
              Label("Restart Server to Apply Changes", systemImage: "arrow.trianglehead.clockwise")
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
        .sheet(isPresented: $showSettings) {
          NavigationStack {
            SettingsView(viewModel: viewModel)
              .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                  Button("Done") {
                    showSettings = false
                  }
                }
              }
          }
        }
      }
      .allowsHitTesting(!isScreenDimmed)

      if isScreenDimmed {
        Color.black
          .ignoresSafeArea()
          .onTapGesture { resetDimTimer() }
      }
    }
    .animation(.default, value: viewModel.isRunning)
    .animation(.default, value: viewModel.hasPairings)
    .onChange(of: viewModel.isRunning) {
      if viewModel.isRunning {
        resetDimTimer()
      } else {
        dimTask?.cancel()
        dimTask = nil
        isScreenDimmed = false
        showSettings = false
      }
    }
    .onChange(of: viewModel.keepScreenAwake) {
      if viewModel.isRunning {
        resetDimTimer()
      }
    }
    .onChange(of: viewModel.screenSaverEnabled) {
      if viewModel.isRunning {
        resetDimTimer()
      }
    }
    .onChange(of: viewModel.screenSaverDelay) {
      if viewModel.isRunning {
        resetDimTimer()
      }
    }
  }

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

#Preview("Stopped") {
  ContentView(viewModel: .preview())
}

#Preview("Pairing") {
  ContentView(viewModel: .preview(running: true))
}

#Preview("Dashboard") {
  ContentView(viewModel: .preview(running: true, paired: true, lightOn: true))
}
