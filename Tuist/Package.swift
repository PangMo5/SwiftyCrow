// swift-tools-version: 5.9
import PackageDescription

#if TUIST
  import ProjectDescription

  let packageSettings = PackageSettings(
    // Customize the product types for specific package product
    // Default is .staticFramework
    // productTypes: ["Alamofire": .framework,]
    productTypes: [:],
    baseSettings: .settings(base: [
      "STRINGS_FILE_OUTPUT_ENCODING": "UTF-8",
    ]),
    targetSettings: [
      "KeyboardShortcuts": [
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
        "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
      ],
    ]
  )
#endif

let package = Package(
  name: "SwiftyCrow",
  dependencies: [
    // Add your own dependencies here:
    // .package(url: "https://github.com/Alamofire/Alamofire", from: "5.0.0"),
    // You can read more about dependencies here: https://docs.tuist.io/documentation/tuist/dependencies
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.25.5"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.7.4"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", branch: "main"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
  ]
)
