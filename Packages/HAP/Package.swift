// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HAP",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "HAP", targets: ["HAP"])
  ],
  dependencies: [
    .package(path: "../TLV8"),
    .package(path: "../SRP"),
    .package(path: "../FragmentedMP4"),
  ],
  targets: [
    .target(name: "HAP", dependencies: ["TLV8", "SRP", "FragmentedMP4"]),
    .testTarget(name: "HAPTests", dependencies: ["HAP"]),
  ]
)
