// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Locked",
  platforms: [.macOS(.v14), .iOS(.v15)],
  products: [
    .library(name: "Locked", targets: ["Locked"])
  ],
  targets: [
    .target(name: "Locked")
  ]
)
