import SwiftUI

struct PairingView: View {
  var viewModel: HAPViewModel
  @State private var qrImage: PlatformImage?

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      if let qr = qrImage {
        Image(platformImage: qr)
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
      let sid = viewModel.setupID
      let cgImage = await Task.detached {
        generateQRCodeCG(from: hapSetupURI(setupCode: code, setupID: sid))
      }.value
      guard !Task.isCancelled, let cgImage else { return }
      qrImage = .from(cgImage: cgImage)
    }
  }
}

#Preview("Pairing") {
  PairingView(viewModel: .preview(running: true))
}
