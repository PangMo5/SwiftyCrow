// swift-tools-version: 5.9
import PackageDescription

#if TUIST
  import ProjectDescription

  let packageSettings = PackageSettings(
    productTypes: [:],
    baseSettings: .settings(base: [
      "STRINGS_FILE_OUTPUT_ENCODING": "UTF-8",
    ])
  )
#endif

let package = Package(
  name: "SwiftyCrow",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.25.5"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.7.4"),
    .package(url: "https://github.com/Clipy/Magnet", from: "3.5.0"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2"),
  ]
)
