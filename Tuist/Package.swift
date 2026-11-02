// swift-tools-version: 6.4

// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
  productTypes: [:],
  baseSettings: .settings(base: [
    "STRINGS_FILE_OUTPUT_ENCODING": "UTF-8"
  ]),
)
#endif

let package = Package(
  name: "SwiftyCrow",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.10.1"),
    .package(url: "https://github.com/Clipy/Magnet", from: "3.5.0"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.1.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
  ],
)
