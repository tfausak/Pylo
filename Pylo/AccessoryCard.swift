import SwiftUI

struct AccessoryCard<Content: View>: View {
  let icon: String
  let title: String
  @Binding var isOn: Bool
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
        Text(title)
          .font(.headline)
        Spacer()
        Toggle(title, isOn: $isOn)
          .labelsHidden()
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
    .background(.quinary, in: .rect(cornerRadius: 12))
    .animation(.default, value: isOn)
  }
}
