import ProjectDescription

let developmentTeam = Environment.developmentTeam.getString(default: "")
let sparklePublicEDKey = Environment.sparklePublicEdKey.getString(default: "")

let project = Project(
  name: "SwiftyCrow",
  targets: [
    .target(
      name: "SwiftyCrow",
      destinations: .macOS,
      product: .app,
      bundleId: "io.tuist.SwiftyCrow",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .extendingDefault(with: [
        "LSUIElement": true,
        "NSScreenCaptureDescription": "SwiftyCrow captures the region under its overlay window to read text.",
        "SUFeedURL": "https://pangmo5.github.io/SwiftyCrow/appcast.xml",
        "SUEnableAutomaticChecks": true,
        "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)",
      ]),
      sources: ["Sources/**"],
      resources: ["Resources/**"],
      dependencies: [
        .external(name: "ComposableArchitecture"),
        .external(name: "DependenciesMacros"),
        .external(name: "Sharing"),
        .external(name: "KeyboardShortcuts"),
        .external(name: "TOML"),
        .external(name: "Sparkle"),
      ],
      settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
        "CODE_SIGN_IDENTITY": "Apple Development",
        "CODE_SIGNING_REQUIRED": "YES",
        "SPARKLE_PUBLIC_ED_KEY": SettingValue(stringLiteral: sparklePublicEDKey),
      ])
    ),
  ]
)
