// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SRTP",
  platforms: [.macOS(.v14), .iOS(.v15)],
  products: [
    .library(name: "SRTP", targets: ["SRTP"])
  ],
  dependencies: [
    .package(path: "../Locked")
  ],
  targets: [
    .target(name: "SRTP", dependencies: ["Locked"]),
    .testTarget(name: "SRTPTests", dependencies: ["SRTP"]),
  ]
)
