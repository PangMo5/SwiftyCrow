import ProjectDescription

let developmentTeam = Environment.developmentTeam.getString(default: "")
let sparklePublicEDKey = Environment.sparklePublicEdKey.getString(default: "")
// Single source of truth for the marketing version. The release workflow
// verifies the pushed tag matches this before building.
let appVersion = "2.6.1"
// Build number is injected by CI (github.run_number); 1 for local builds.
let buildNumber = Environment.buildNumber.getString(default: "1")

let project = Project(
  name: "SwiftyCrow",
  targets: [
    .target(
      name: "SwiftyCrow",
      destinations: .macOS,
      product: .app,
      bundleId: "dev.PangMo5.SwiftyCrow",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSUIElement": true,
        "NSScreenCaptureDescription": "SwiftyCrow captures the region under its overlay window to read text.",
        "SUFeedURL": "https://pangmo5.dev/SwiftyCrow/appcast.xml",
        "SUEnableAutomaticChecks": true,
        "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)",
      ]),
      sources: ["Sources/**"],
      resources: ["Resources/**"],
      dependencies: [
        .external(name: "ComposableArchitecture"),
        .external(name: "DependenciesMacros"),
        .external(name: "Sharing"),
        .external(name: "Magnet"),
        .external(name: "TOML"),
        .external(name: "Sparkle"),
      ],
      settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
        "CODE_SIGN_IDENTITY": "Apple Development",
        "CODE_SIGNING_REQUIRED": "YES",
        "SPARKLE_PUBLIC_ED_KEY": SettingValue(stringLiteral: sparklePublicEDKey),
        "MARKETING_VERSION": SettingValue(stringLiteral: appVersion),
        "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
      ])
    ),
  ]
)
