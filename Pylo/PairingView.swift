import SwiftUI

struct PairingView: View {
  var viewModel: HAPViewModel
  @State private var qrImage: UIImage?

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      if let qr = qrImage {
        Image(uiImage: qr)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 200, height: 200)
      } else {
        RoundedRectangle(cornerRadius: 12)
          .fill(.quaternary)
          .frame(width: 200, height: 200)
      }

      Text(viewModel.setupCode)
        .font(.system(.largeTitle, design: .monospaced))
        .fontWeight(.bold)

      Text("Scan with the Home app\nor enter the code manually")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Spacer()

      HStack(spacing: 4) {
        Circle()
          .fill(.green)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
        Text("Running")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(viewModel.statusMessage)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .padding()
    .task(id: viewModel.setupCode) {
      let code = viewModel.setupCode
      let image = await Task.detached {
          await generateQRCode(from: hapSetupURI(setupCode: code))
      }.value
      qrImage = image
    }
  }
}

#Preview("Pairing") {
  NavigationStack {
    PairingView(viewModel: .preview(running: true))
      .navigationTitle("Pylo")
  }
}
