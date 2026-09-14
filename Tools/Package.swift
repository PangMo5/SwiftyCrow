// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

/// Automation dependencies remain outside the app and offline recording tools.
let package = Package(
  name: "SwiftyCrowTools",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "swiftycrow-tools", targets: ["swiftycrow-tools"])],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.5.0"),
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.9"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.8.0")),
    .package(url: "https://github.com/swiftlang/swift-cmark.git", .upToNextMinor(from: "0.8.0")),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
  ],
  targets: [
    .target(name: "SwiftyCrowToolsKit", dependencies: [
      .product(name: "Subprocess", package: "swift-subprocess"),
      .product(name: "ArgumentParser", package: "swift-argument-parser"),
      .product(name: "Crypto", package: "swift-crypto"),
      .product(name: "SystemPackage", package: "swift-system"),
      .product(name: "SwiftSoup", package: "SwiftSoup"),
      .product(name: "Markdown", package: "swift-markdown"),
      .product(name: "cmark-gfm", package: "swift-cmark"),
      .product(name: "Hummingbird", package: "hummingbird"),
    ]),
    .executableTarget(name: "swiftycrow-tools", dependencies: ["SwiftyCrowToolsKit"]),
    .testTarget(name: "SwiftyCrowToolsTests", dependencies: ["SwiftyCrowToolsKit"]),
  ]
)
