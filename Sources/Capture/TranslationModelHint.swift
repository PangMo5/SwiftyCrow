// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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

// MARK: - PreparingRecognitionNote

/// An elapsed-time hint while recognition and layout analysis are in progress.
/// Vision does not expose a separate model-loading phase. Non-interactive so
/// the overlay's pass-through stays untouched.
struct PreparingRecognitionNote: View {
  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      VStack(alignment: .leading, spacing: 1) {
        Text("Processing screen text")
          .font(.caption)
          .fontWeight(.semibold)
        Text("Recognizing text and analyzing its layout. Processing time depends on the image.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial)
  }
}

// MARK: - TranslationModelHint

/// Compact failure banner for capture results, detached live results and the
/// menu bar. Every presentation includes the same explanation and recovery action.
struct TranslationModelHint: View {
  var message: String? = nil

  var body: some View {
    TranslationFailureDetails(message: message)
      .font(.caption)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.orange.opacity(0.18))
      .background(.regularMaterial)
  }
}

// MARK: - TranslationFailureDetails

/// Shared by failure banners and the overlay popover. An old preference to
/// dismiss setup advice must never suppress an active failure's recovery action.
struct TranslationFailureDetails: View {
  var message: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Translation unavailable", systemImage: "exclamationmark.triangle.fill")
        .fontWeight(.semibold)
        .foregroundStyle(.orange)
      Text(message ?? String(localized:
        "Add the required language model in System Settings → General → Language & Region → Translation Languages, then capture again."))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Open Settings", action: openLanguageSettings)
        .controlSize(.small)
    }
  }
}

// MARK: - CaptureStatusNote

struct CaptureStatusNote: View {
  let lines: [OverlayLine]

  var body: some View {
    if lines.contains(where: { $0.source.needsReview }) {
      Label("Some text may be misread. Compare the translation with the original.", systemImage: "text.magnifyingglass")
        .font(.caption2).foregroundStyle(.orange)
        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
    }
  }
}
