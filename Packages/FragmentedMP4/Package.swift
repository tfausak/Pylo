// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FragmentedMP4",
  platforms: [.macOS(.v12), .iOS(.v15)],
  products: [
    .library(name: "FragmentedMP4", targets: ["FragmentedMP4"])
  ],
  targets: [
    .target(name: "FragmentedMP4"),
    .testTarget(name: "FragmentedMP4Tests", dependencies: ["FragmentedMP4"]),
  ]
)
