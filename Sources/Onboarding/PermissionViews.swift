// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// MARK: - ScreenRecordingPermissionRow

struct ScreenRecordingPermissionRow: View {
  let granted: Bool
  let isRequesting: Bool
  let grant: () -> Void
  let openSettings: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(granted ? Color.green : Color.orange)
      VStack(alignment: .leading, spacing: 4) {
        Text("Screen Recording").font(.headline)
        Text(granted
          ? "Granted. Capture and live translation can read the selected screen area."
          : "Required to recognize text on your screen. Allow access in System Settings, then relaunch.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button(granted ? "Open System Settings" : "Set Up Access…", action: granted ? openSettings : grant)
        .disabled(isRequesting)
    }
  }
}

// MARK: - PermissionRelaunchNotice

struct PermissionRelaunchNotice: View {
  let isRelaunching: Bool
  let error: String?
  let relaunch: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Relaunch after granting access", systemImage: "arrow.clockwise.circle")
        .font(.headline).foregroundStyle(.orange)
      Text("Relaunch to apply permission changes. If setup is open, you will return to the same step and language choice.")
        .font(.callout).foregroundStyle(.secondary)
      Button("Relaunch SwiftyCrow", action: relaunch).disabled(isRelaunching)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
  }
}
