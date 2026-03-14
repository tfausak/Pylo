import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

struct PairingView: View {
  var viewModel: HAPViewModel
  #if os(iOS)
    @State private var qrImage: UIImage?
  #elseif os(macOS)
    @State private var qrImage: NSImage?
  #endif

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      if let qr = qrImage {
        #if os(iOS)
          Image(uiImage: qr)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 200, height: 200)
            .accessibilityLabel("HomeKit setup QR code")
        #elseif os(macOS)
          Image(nsImage: qr)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 200, height: 200)
            .accessibilityLabel("HomeKit setup QR code")
        #endif
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
      #if os(iOS)
        qrImage = UIImage(cgImage: cgImage)
      #elseif os(macOS)
        qrImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
      #endif
    }
  }
}

#Preview("Pairing") {
  PairingView(viewModel: .preview(running: true))
}
