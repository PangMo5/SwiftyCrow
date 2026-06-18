import AppKit
import SwiftUI

// MARK: - Open Language Settings

/// Opens System Settings → General → Language & Region, where the user adds
/// on-device translation models via "Translation Languages…".
@MainActor
func openLanguageSettings() {
  guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
  NSWorkspace.shared.open(url)
}

// MARK: - TranslationModelHint

/// Shown when translation fails because the on-device model isn't installed.
/// The Translation framework only translates languages downloaded in System
/// Settings, so this explains the situation and links straight there.
struct TranslationModelHint: View {
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 1) {
        Text("Translation model not installed")
          .font(.caption)
          .fontWeight(.semibold)
        Text("Add the language under System Settings → General → Language & Region → Translation Languages, then capture again.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button("Open Settings", action: openLanguageSettings)
        .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(0.18))
    .background(.regularMaterial)
  }
}
