import SwiftUI

struct WelcomeView: View {
  var onGetStarted: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "house.fill")
        .font(.system(size: 64))
        .foregroundStyle(Color.accentColor)

      Text("Welcome to Pylo")
        .font(.largeTitle.weight(.bold))

      Text(
        "Turn this device into a HomeKit bridge with native accessories — camera, flashlight, sensors, and more."
      )
      .font(.body)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal)

      #if os(iOS)
        Text("Pylo must remain in the foreground with the screen on to work.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      #endif

      Spacer()

      Button {
        onGetStarted()
      } label: {
        Text("Get Started")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
      }
      .buttonStyle(.borderedProminent)
      .padding(.horizontal, 40)
      .padding(.bottom, 32)
    }
    .padding()
  }
}

#Preview {
  WelcomeView(onGetStarted: {})
}
