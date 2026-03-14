// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TLV8",
  platforms: [.macOS(.v12), .iOS(.v15)],
  products: [
    .library(name: "TLV8", targets: ["TLV8"])
  ],
  targets: [
    .target(name: "TLV8"),
    .testTarget(name: "TLV8Tests", dependencies: ["TLV8"]),
  ]
)
