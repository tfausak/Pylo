import SwiftUI

struct RunningView: View {
  @ObservedObject var viewModel: HAPViewModel
  @State private var showConfig = false
  @State private var pixelOffset = CGSize.zero
  @State private var buttonCooldown = false

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      if viewModel.buttonEnabled {
        buttonTile
          .offset(pixelOffset)
      }
    }
    .overlay(alignment: .top) {
      HStack {
        statusIndicator
        Spacer()
        gearButton
      }
      .padding(.horizontal, 12)
      .offset(pixelOffset)
    }
    .task { await pixelShiftLoop() }
    #if os(iOS)
      .fullScreenCover(isPresented: $showConfig) {
        RunningConfigView(viewModel: viewModel)
      }
    #else
      .sheet(isPresented: $showConfig) {
        RunningConfigView(viewModel: viewModel)
      }
    #endif
  }

  // MARK: - Status Indicator

  private var statusIndicator: some View {
    Image(systemName: "checkmark.circle")
      .font(.title2)
      .foregroundStyle(.green)
      .padding(20)
  }

  // MARK: - Button

  private var buttonTile: some View {
    Button {
      guard !buttonCooldown else { return }
      viewModel.pressButton()
      #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      #endif
      buttonCooldown = true
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        buttonCooldown = false
      }
    } label: {
      Image(systemName: "hand.tap")
        .font(.system(size: 48))
        .foregroundStyle(buttonCooldown ? .gray : .white)
        .frame(width: 150, height: 150)
        .background(
          ZStack {
            Circle()
              .fill(buttonCooldown ? Color.gray.opacity(0.3) : Color.white.opacity(0.15))
            Circle()
              .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
          }
        )
    }
    .disabled(buttonCooldown)
    .animation(.easeInOut(duration: 0.2), value: buttonCooldown)
    .accessibilityLabel("Button")
    .accessibilityHint("Triggers a programmable switch event")
  }

  // MARK: - Gear Button

  private var gearButton: some View {
    Button {
      showConfig = true
    } label: {
      Image(systemName: "gearshape.fill")
        .font(.title2)
        .foregroundStyle(.white.opacity(0.5))
        .padding(20)
    }
    .accessibilityLabel("Settings")
  }

  // MARK: - Pixel Shift

  @MainActor
  private func pixelShiftLoop() async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(nanoseconds: 60_000_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 1.0)) {
        pixelOffset = CGSize(
          width: CGFloat.random(in: -3...3),
          height: CGFloat.random(in: -3...3)
        )
      }
    }
  }
}

struct RunningConfigView: View {
  @ObservedObject var viewModel: HAPViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var savedConfig: AccessoryConfig?

  var body: some View {
    NavigationView {
      ContentView(viewModel: viewModel, forceConfig: true)
        .navigationTitle("Settings")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(viewModel.needsRestart ? "Cancel" : "Close") {
              if let savedConfig {
                viewModel.restoreConfig(savedConfig)
              }
              dismiss()
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              viewModel.restart()
              dismiss()
            }
            .font(.body.weight(.semibold))
            .disabled(!viewModel.needsRestart)
          }
        }
    }
    #if os(iOS)
      .navigationViewStyle(.stack)
    #else
      .frame(minWidth: 480, minHeight: 500)
    #endif
    .interactiveDismissDisabled(viewModel.needsRestart)
    .onAppear {
      savedConfig = AccessoryConfig(from: viewModel)
    }
  }
}
