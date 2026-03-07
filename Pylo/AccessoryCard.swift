import SwiftUI

struct AccessoryCard<Content: View>: View {
  let icon: String
  let title: String
  @Binding var isOn: Bool
  var blocked: Bool = false
  var blockedMessage: String?
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      // Header row: icon, title, toggle
      HStack {
        Image(systemName: icon)
          .font(.title3)
          .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
          .frame(width: 28)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          if blocked, let blockedMessage {
            Text(blockedMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Toggle(title, isOn: $isOn)
          .labelsHidden()
          .tint(blocked ? Color.secondary : nil)
          .disabled(blocked)
      }
      .padding()

      // Expanded content when toggle is on
      if isOn {
        Divider()
          .padding(.horizontal)
        content()
          .padding()
      }
    }
    .background(
      Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12)
    )
    .animation(.default, value: isOn)
  }
}
