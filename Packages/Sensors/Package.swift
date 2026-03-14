// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Sensors",
  platforms: [.macOS(.v12), .iOS(.v15)],
  products: [
    .library(name: "Sensors", targets: ["Sensors"])
  ],
  dependencies: [
    .package(path: "../HAP"),
    .package(path: "../Locked"),
  ],
  targets: [
    .target(name: "Sensors", dependencies: ["HAP", "Locked"])
  ]
)
