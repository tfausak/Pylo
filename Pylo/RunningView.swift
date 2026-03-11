import SwiftUI

struct RunningView: View {
  @ObservedObject var viewModel: HAPViewModel
  @State private var showConfig = false
  @State private var pixelOffset = CGSize.zero
  @State private var shiftTimer: Timer?
  @State private var buttonCooldown = false

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      VStack(spacing: 40) {
        statusIndicator

        if viewModel.buttonEnabled {
          buttonTile
        }
      }
      .offset(pixelOffset)
    }
    .overlay(alignment: .topTrailing) {
      gearButton
        .offset(pixelOffset)
    }
    .onAppear { startPixelShift() }
    .onDisappear { stopPixelShift() }
    .fullScreenCover(isPresented: $showConfig) {
      ConfigView(viewModel: viewModel)
    }
  }

  // MARK: - Status Indicator

  private var statusIndicator: some View {
    HStack(spacing: 6) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
      Text("Running")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Button

  private var buttonTile: some View {
    Button {
      guard !buttonCooldown else { return }
      viewModel.pressButton()
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      buttonCooldown = true
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        buttonCooldown = false
      }
    } label: {
      Image(systemName: "bell.fill")
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

  private func startPixelShift() {
    shiftTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
      Task { @MainActor in
        withAnimation(.easeInOut(duration: 1.0)) {
          pixelOffset = CGSize(
            width: CGFloat.random(in: -3...3),
            height: CGFloat.random(in: -3...3)
          )
        }
      }
    }
  }

  private func stopPixelShift() {
    shiftTimer?.invalidate()
    shiftTimer = nil
  }
}

struct ConfigView: View {
  @ObservedObject var viewModel: HAPViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationView {
      ConfigCardsView(viewModel: viewModel)
        .navigationTitle("Settings")
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            Button("Done") { dismiss() }
          }
        }
    }
    .navigationViewStyle(.stack)
  }
}
