import ProjectDescription

let bundleIdPrefix = "dev.PangMo5"

let developmentTeam = Environment.developmentTeam.getString(default: "")
let sparklePublicEDKey = Environment.sparklePublicEdKey.getString(default: "")
// Single source of truth for the marketing version. The release workflow
// verifies the pushed tag matches this before building.
let appVersion = "2.8.0"
// Build number is injected by CI (github.run_number); 1 for local builds.
let buildNumber = Environment.buildNumber.getString(default: "1")

let baseSettings: SettingsDictionary = [
  "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
  // Sign local builds with the developer's Apple Development cert so the binary's
  // designated requirement stays stable across rebuilds. Tuist otherwise defaults
  // macOS targets to ad-hoc ("-") signing, whose requirement is the binary hash —
  // it changes every build, so macOS re-prompts for Screen Recording (TCC) on each
  // run. The release workflow overrides this with Developer ID for notarization.
  "CODE_SIGN_STYLE": "Automatic",
  "CODE_SIGN_IDENTITY": "Apple Development",
  // Hardened Runtime is turned back on by the release archive (for notarization);
  // off locally so debug builds sign cleanly without provisioning friction.
  "ENABLE_HARDENED_RUNTIME": "NO",
]

let signingSettings: SettingsDictionary = [
  // Re-pin signing on the target too (Tuist's per-target default is ad-hoc).
  "CODE_SIGN_STYLE": "Automatic",
  "CODE_SIGN_IDENTITY": "Apple Development",
  "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
]

let project = Project(
  name: "SwiftyCrow",
  organizationName: "PangMo5",
  settings: .settings(base: baseSettings),
  targets: [
    .target(
      name: "SwiftyCrow",
      destinations: .macOS,
      product: .app,
      bundleId: "\(bundleIdPrefix).SwiftyCrow",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSUIElement": true,
        // Display name (and the Privacy & Security / TCC list name) track the
        // configuration, so the Debug build reads as "SwiftyCrow Dev" — a
        // distinct app from an installed release.
        "CFBundleDisplayName": "$(APP_DISPLAY_NAME)",
        "CFBundleName": "$(APP_DISPLAY_NAME)",
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
      settings: .settings(
        base: signingSettings.merging([
          "MARKETING_VERSION": SettingValue(stringLiteral: appVersion),
          "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
          "SPARKLE_PUBLIC_ED_KEY": SettingValue(stringLiteral: sparklePublicEDKey),
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
          // Release display name; the Debug configuration overrides it below.
          "APP_DISPLAY_NAME": "SwiftyCrow",
        ]) { $1 },
        configurations: [
          // The Debug build is a *distinct* app to macOS — its own bundle id and
          // display name — so its Screen Recording (TCC) grant is separate from an
          // installed Release build and the two never fight over one TCC entry
          // (which forced re-granting the permission on every dev run). Combined
          // with the stable Apple Development signature above, the dev grant then
          // survives rebuilds. The config path is bundle-id-independent, so dev
          // and release still share ~/.config/SwiftyCrow/config.toml.
          .debug(name: "Debug", settings: [
            "PRODUCT_BUNDLE_IDENTIFIER": "\(bundleIdPrefix).SwiftyCrow.debug",
            "APP_DISPLAY_NAME": "SwiftyCrow Dev",
            // DEV-badged icon so the dev build is visually distinct in the Dock
            // / app switcher (a red "DEV" band, mirroring the Tatami dev icon).
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon-Debug",
          ]),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
