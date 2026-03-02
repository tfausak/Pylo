// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FragmentedMP4",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "FragmentedMP4", targets: ["FragmentedMP4"])
  ],
  targets: [
    .target(name: "FragmentedMP4"),
    .testTarget(name: "FragmentedMP4Tests", dependencies: ["FragmentedMP4"]),
  ]
)
