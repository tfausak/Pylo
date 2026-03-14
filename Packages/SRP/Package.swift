// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SRP",
  platforms: [.macOS(.v12), .iOS(.v15)],
  products: [
    .library(name: "SRP", targets: ["SRP"])
  ],
  dependencies: [
    .package(path: "../Locked"),
    .package(url: "https://github.com/attaswift/BigInt.git", from: "5.1.0"),
  ],
  targets: [
    .target(name: "SRP", dependencies: ["Locked", "BigInt"]),
    .testTarget(name: "SRPTests", dependencies: ["SRP", "BigInt"]),
  ]
)
