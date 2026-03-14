// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SRTP",
  platforms: [.macOS(.v13), .iOS(.v15)],
  products: [
    .library(name: "SRTP", targets: ["SRTP"])
  ],
  targets: [
    .target(name: "SRTP"),
    .testTarget(name: "SRTPTests", dependencies: ["SRTP"]),
  ]
)
