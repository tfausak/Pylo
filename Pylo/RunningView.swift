import SwiftUI

struct RunningView: View {
  @ObservedObject var viewModel: HAPViewModel
  @State private var showConfig = false
  @State private var pixelOffset = CGSize.zero
  @State private var buttonCooldown = false
  #if os(iOS)
    @State private var screenSaverActive = false
    @State private var screenSaverOffset = CGSize.zero
    @State private var lastInteraction = Date()
  #endif

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      #if os(iOS)
        if screenSaverActive {
          screenSaverOverlay
            .offset(screenSaverOffset)
            .transition(.opacity)
        }
      #endif

      if viewModel.buttonEnabled {
        buttonTile
          .offset(pixelOffset)
      }
    }
    .overlay(alignment: .top) {
      #if os(iOS)
        if !screenSaverActive {
          topBar
        }
      #else
        topBar
      #endif
    }
    #if os(iOS)
      .contentShape(Rectangle())
      .onTapGesture {
        if screenSaverActive {
          withAnimation(.easeOut(duration: 0.3)) {
            screenSaverActive = false
          }
        }
        lastInteraction = Date()
      }
    #endif
    .task { await pixelShiftLoop() }
    #if os(iOS)
      .task { await screenSaverLoop() }
      .fullScreenCover(isPresented: $showConfig) {
        RunningConfigView(viewModel: viewModel)
      }
      .onChange(of: showConfig) { _ in
        lastInteraction = Date()
      }
    #else
      .sheet(isPresented: $showConfig) {
        RunningConfigView(viewModel: viewModel)
      }
    #endif
  }

  private var topBar: some View {
    HStack {
      statusIndicator
      Spacer()
      gearButton
    }
    .padding(.horizontal, 12)
    .offset(pixelOffset)
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
        lastInteraction = Date()
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
      try? await Task.sleep(nanoseconds: 60_000_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 1.0)) {
        pixelOffset = CGSize(
          width: CGFloat.random(in: -3...3),
          height: CGFloat.random(in: -3...3)
        )
      }
    }
  }

  // MARK: - Screen Saver (iOS)

  #if os(iOS)
    private var screenSaverOverlay: some View {
      Text(Date(), style: .time)
        .font(.system(size: 48, weight: .thin, design: .rounded))
        .foregroundStyle(.white.opacity(0.4))
    }

    @MainActor
    private func screenSaverLoop() async {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard !Task.isCancelled else { return }
        guard viewModel.screenSaverEnabled else { continue }

        let elapsed = Date().timeIntervalSince(lastInteraction)
        if elapsed >= viewModel.screenSaverDelay.duration && !screenSaverActive {
          withAnimation(.easeIn(duration: 1.0)) {
            screenSaverActive = true
          }
        }

        if screenSaverActive {
          withAnimation(.easeInOut(duration: 3.0)) {
            screenSaverOffset = CGSize(
              width: CGFloat.random(in: -40...40),
              height: CGFloat.random(in: -100...100)
            )
          }
        }
      }
    }
  #endif
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
