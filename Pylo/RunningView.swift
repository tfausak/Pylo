import SwiftUI

struct RunningView: View {
  @ObservedObject var viewModel: HAPViewModel
  @AppStorage(PrefKey.needsInitialConfig) private var needsInitialConfig = false
  @State private var showConfig = false
  @State private var pixelOffset = CGSize.zero
  @State private var buttonCooldown = false

  private enum Focus: Hashable { case tap, gear }
  @FocusState private var focus: Focus?

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      if viewModel.buttonEnabled {
        buttonTile
          .focused($focus, equals: .tap)
          .offset(pixelOffset)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { focus = nil }
    .overlay(alignment: .topTrailing) {
      gearButton
        .focused($focus, equals: .gear)
        .padding(.horizontal, 12)
        .offset(pixelOffset)
    }
    .task { await pixelShiftLoop() }
    .onAppear {
      DispatchQueue.main.async { focus = nil }
      if needsInitialConfig {
        needsInitialConfig = false
        showConfig = true
      }
    }
    #if os(iOS)
      .navigationBarHidden(true)
      .fullScreenCover(isPresented: $showConfig, onDismiss: restartIfNeeded) {
        RunningConfigView(viewModel: viewModel)
      }
    #else
      .sheet(isPresented: $showConfig, onDismiss: restartIfNeeded) {
        RunningConfigView(viewModel: viewModel)
      }
    #endif
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
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        buttonCooldown = false
      }
    } label: {
      Image(systemName: buttonCooldown ? "checkmark" : "hand.tap")
        .font(.system(size: 56))
        .foregroundStyle(buttonCooldown ? .gray : .white)
        .frame(width: 170, height: 170)
        .overlay(
          Circle()
            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
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
      Image(systemName: "gear")
        .font(.title2)
        .foregroundStyle(.white.opacity(0.5))
        .padding(20)
    }
    .contentShape(Rectangle())
    .buttonStyle(.plain)
    .accessibilityLabel("Settings")
  }

  private func restartIfNeeded() {
    if viewModel.needsRestart {
      viewModel.restart()
    }
    viewModel.requestAppReviewIfEligible()
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

  var body: some View {
    navigationWrapper {
      ContentView(viewModel: viewModel, forceConfig: true)
        .navigationTitle("Settings")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              dismiss()
            }
            .font(.body.weight(.semibold))
          }
        }
        .safeAreaInset(edge: .bottom) {
          if viewModel.needsRestart {
            Text("Server will restart on close")
              .font(.subheadline.weight(.medium))
              .frame(maxWidth: .infinity)
              .padding(12)
              .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
              .padding(.horizontal)
              .padding(.bottom, 4)
              .transition(.move(edge: .bottom).combined(with: .opacity))
          }
        }
        .animation(.default, value: viewModel.needsRestart)
    }
    #if os(macOS)
      .frame(minWidth: 480, minHeight: 500)
    #endif
  }

  @ViewBuilder
  private func navigationWrapper<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    if #available(iOS 16.0, macOS 13.0, *) {
      NavigationStack(root: content)
    } else {
      NavigationView(content: content)
        #if os(iOS)
          .navigationViewStyle(.stack)
        #endif
    }
  }
}
