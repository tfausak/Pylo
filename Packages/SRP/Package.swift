// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SRP",
  platforms: [.macOS(.v13), .iOS(.v15)],
  products: [
    .library(name: "SRP", targets: ["SRP"])
  ],
  dependencies: [
    .package(url: "https://github.com/attaswift/BigInt.git", from: "5.1.0")
  ],
  targets: [
    .target(name: "SRP", dependencies: ["BigInt"]),
    .testTarget(name: "SRPTests", dependencies: ["SRP", "BigInt"]),
  ]
)
