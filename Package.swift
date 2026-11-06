// swift-tools-version: 6.4
// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import PackageDescription

let localizationOutput = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent(".build/localized-strings").path

let package = Package(
  name: "SwiftyCrow",
  platforms: [.macOS(.v26)],
  // The app and standalone quality probes load the same compiled module.
  products: [.library(name: "SwiftyCrow", type: .dynamic, targets: ["SwiftyCrow"])],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.2"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.10.1"),
    .package(url: "https://github.com/Clipy/Magnet", from: "3.5.0"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.1.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
  ],
  targets: [
    .target(
      name: "SwiftyCrow",
      dependencies: [
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
        .product(name: "Sharing", package: "swift-sharing"),
        .product(name: "Magnet", package: "Magnet"),
        .product(name: "TOML", package: "swift-toml"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "Sources",
      swiftSettings: [.unsafeFlags(["-emit-localized-strings", "-emit-localized-strings-path", localizationOutput])],
    ),
    .testTarget(name: "SwiftyCrowTests", dependencies: ["SwiftyCrow"], path: "Tests", exclude: ["Execution"]),
    // Swift Build runs test bundles in separate processes. TestStore overrides
    // the process-wide executor; real executor and AppKit checks need isolation.
    .testTarget(name: "SwiftyCrowExecutionTests", dependencies: ["SwiftyCrow"], path: "Tests/Execution"),
  ],
  swiftLanguageModes: [.v5],
)
