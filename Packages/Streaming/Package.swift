// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Streaming",
  platforms: [.macOS(.v14), .iOS(.v15)],
  products: [
    .library(name: "Streaming", targets: ["Streaming"])
  ],
  dependencies: [
    .package(path: "../FragmentedMP4"),
    .package(path: "../Locked"),
    .package(path: "../Sensors"),
    .package(path: "../SRTP"),
  ],
  targets: [
    .target(name: "Streaming", dependencies: ["FragmentedMP4", "Locked", "Sensors", "SRTP"])
  ]
)
