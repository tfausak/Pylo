import SwiftUI

struct PairingView: View {
  /// Nil while the server is starting, since starting may rotate the credentials.
  var setupCode: String?
  var setupID: String
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

      Text(setupCode ?? "000-00-000")
        .font(.system(.largeTitle, design: .monospaced))
        .fontWeight(.bold)
        .redacted(reason: setupCode == nil ? .placeholder : [])

      Text("Scan with the Home app\nor enter the code manually")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Spacer()
    }
    .padding()
    .task(id: [setupCode, setupID]) {
      qrImage = nil
      guard let code = setupCode else { return }
      let sid = setupID
      let cgImage = await Task.detached {
        generateQRCodeCG(from: hapSetupURI(setupCode: code, setupID: sid))
      }.value
      guard !Task.isCancelled, let cgImage else { return }
      qrImage = .from(cgImage: cgImage)
    }
  }
}

#Preview("Pairing") {
  let vm = HAPViewModel.preview(running: true)
  PairingView(setupCode: vm.setupCode, setupID: vm.setupID)
}
