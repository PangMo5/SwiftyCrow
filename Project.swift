import ProjectDescription

let developmentTeam = Environment.developmentTeam.getString(default: "")

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
      ]),
      sources: ["Sources/**"],
      resources: ["Resources/**"],
      dependencies: [
        .external(name: "ComposableArchitecture"),
        .external(name: "Sharing"),
        .external(name: "KeyboardShortcuts"),
        .external(name: "TOML"),
      ],
      settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
        "CODE_SIGN_IDENTITY": "Apple Development",
        "CODE_SIGNING_REQUIRED": "YES",
      ])
    ),
  ]
)
