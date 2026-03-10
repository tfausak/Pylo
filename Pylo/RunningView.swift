import SwiftUI

struct RunningView: View {
  @ObservedObject var viewModel: HAPViewModel
  @State private var showConfig = false
  @State private var pixelOffset = CGSize.zero
  @State private var shiftTimer: Timer?
  @State private var doorbellCooldown = false

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      VStack(spacing: 40) {
        statusIndicator

        if viewModel.doorbellEnabled, viewModel.selectedStreamCamera != nil {
          doorbellButton
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

  // MARK: - Doorbell Button

  private var doorbellButton: some View {
    Button {
      guard !doorbellCooldown else { return }
      viewModel.ringDoorbell()
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      doorbellCooldown = true
      Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        doorbellCooldown = false
      }
    } label: {
      Image(systemName: "bell.fill")
        .font(.system(size: 48))
        .foregroundStyle(doorbellCooldown ? .gray : .white)
        .frame(width: 150, height: 150)
        .background(
          ZStack {
            Circle()
              .fill(doorbellCooldown ? Color.gray.opacity(0.3) : Color.white.opacity(0.15))
            Circle()
              .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
          }
        )
    }
    .disabled(doorbellCooldown)
    .animation(.easeInOut(duration: 0.2), value: doorbellCooldown)
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
