// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import DependenciesMacros

// MARK: - AppRelaunchClient

@DependencyClient
struct AppRelaunchClient: Sendable {
  /// Flush app-local setup progress before handing control to macOS, which may
  /// perform its own Quit & Reopen without going through our relaunch button.
  var prepare: @Sendable () async -> Void = { }
  var relaunch: @Sendable () async throws -> Void
}

// MARK: DependencyKey

extension AppRelaunchClient: DependencyKey {
  static let liveValue = AppRelaunchClient(
    prepare: { UserDefaults.standard.synchronize() },
    relaunch: {
      _ = await MainActor.run { UserDefaults.standard.synchronize() }
      try await MainActor.run {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        // Keep the selected configuration scope across Launch Services relaunch.
        if let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
          task.arguments?.append(contentsOf: ["--env", "XDG_CONFIG_HOME=\(configHome)"])
        }
        if
          let index = CommandLine.arguments.firstIndex(of: "-AppleLanguages"),
          CommandLine.arguments.indices.contains(index + 1)
        {
          task.arguments?.append(contentsOf: ["--args", "-AppleLanguages", CommandLine.arguments[index + 1]])
        }
        try task.run()
        NSApp.terminate(nil)
      }
    }
  )
  static let testValue = AppRelaunchClient(prepare: { }, relaunch: { })
}

extension DependencyValues {
  var appRelaunch: AppRelaunchClient {
    get { self[AppRelaunchClient.self] }
    set { self[AppRelaunchClient.self] = newValue }
  }
}
