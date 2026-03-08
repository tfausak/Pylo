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
          .accessibilityLabel("HomeKit setup QR code")
      } else {
        RoundedRectangle(cornerRadius: 12)
          .fill(.quaternary)
          .frame(width: 200, height: 200)
          .accessibilityLabel("Loading QR code")
      }

      Text(viewModel.setupCode)
        .font(.system(.largeTitle, design: .monospaced))
        .fontWeight(.bold)

      Text("Scan with the Home app\nor enter the code manually")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Spacer()
    }
    .padding()
    .task(id: viewModel.setupCode) {
      let code = viewModel.setupCode
      let image = await Task.detached(priority: .userInitiated) {
        generateQRCode(from: hapSetupURI(setupCode: code))
      }.value
      guard !Task.isCancelled else { return }
      qrImage = image
    }
  }
}

#Preview("Pairing") {
  PairingView(viewModel: .preview(running: true))
}
