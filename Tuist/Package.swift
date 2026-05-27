// swift-tools-version: 5.9
import PackageDescription

#if TUIST
  import ProjectDescription

  let packageSettings = PackageSettings(
    productTypes: [:],
    baseSettings: .settings(base: [
      "STRINGS_FILE_OUTPUT_ENCODING": "UTF-8",
    ]),
    targetSettings: [
      "KeyboardShortcuts": [
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
        "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
        // The Xcode 26 SIL optimizer crashes inlining KeyboardShortcuts at
        // -O (Release). Disable optimization for just this module.
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
      ],
    ]
  )
#endif

let package = Package(
  name: "SwiftyCrow",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.25.5"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.7.4"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", branch: "main"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2"),
  ]
)
