import SwiftUI

struct PairingView: View {
  var viewModel: HAPViewModel
  private let qrImage: UIImage?

  init(viewModel: HAPViewModel) {
    self.viewModel = viewModel
    self.qrImage = generateQRCode(from: hapSetupURI(setupCode: viewModel.setupCode))
  }

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      if let qr = qrImage {
        Image(uiImage: qr)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
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
  }
}

#Preview("Pairing") {
  NavigationStack {
    PairingView(viewModel: .preview(running: true))
      .navigationTitle("Pylo")
  }
}
