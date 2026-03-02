// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SRTP",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "SRTP", targets: ["SRTP"])
  ],
  targets: [
    .target(name: "SRTP"),
    .testTarget(name: "SRTPTests", dependencies: ["SRTP"]),
  ]
)
