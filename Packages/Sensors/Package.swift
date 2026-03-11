// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Sensors",
  platforms: [.macOS(.v14), .iOS(.v15)],
  products: [
    .library(name: "Sensors", targets: ["Sensors"])
  ],
  dependencies: [
    .package(path: "../Locked")
  ],
  targets: [
    .target(name: "Sensors", dependencies: ["Locked"])
  ]
)
