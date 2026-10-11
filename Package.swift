// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Parlance",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "ParlanceCore", targets: ["ParlanceCore"]),
    .executable(name: "pl", targets: ["pl"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    // Before 1.0 a minor release may break the API, so stay on 0.4.x.
    .package(url: "https://github.com/dduan/TOMLDecoder", .upToNextMinor(from: "0.4.5")),
  ],
  targets: [
    // No external dependencies and no UI framework imports, so the app can share the core.
    .target(name: "ParlanceCore"),
    // A library, so tests can drive commands in-process; `pl` is only its entry point.
    .target(
      name: "ParlanceCLI",
      dependencies: [
        "ParlanceCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "TOMLDecoder", package: "TOMLDecoder"),
      ]
    ),
    .executableTarget(name: "pl", dependencies: ["ParlanceCLI"]),
    .testTarget(
      name: "ParlanceCoreTests", dependencies: ["ParlanceCore"], exclude: ["Fixtures"]),
    .testTarget(
      name: "ParlanceCLITests",
      dependencies: [
        "ParlanceCLI",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
