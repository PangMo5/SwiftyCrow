// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// MARK: - WhatsNewView

struct WhatsNewView: View {

  // MARK: Internal

  let version: String
  let onDone: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            Text("What's New in SwiftyCrow \(version)").font(.title.weight(.semibold))
            Text("A clearer place to start, smoother live translation, and more ways to use the text on your screen.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          Label("Highlights", systemImage: "sparkles").font(.headline)
          item(
            "A fresh translation menu",
            icon: "menubar.rectangle",
            detail: "Start a capture or live translation in one click. See your languages and control an active translation from the menu bar."
          )
          item(
            "An easier first start",
            icon: "hand.wave",
            detail: "Quick Setup guides you through screen access, language downloads, and your first capture. Reopen it anytime from the menu bar."
          )
          item(
            "Steadier live translation",
            icon: "waveform",
            detail: "Changing video frames no longer keep clearing subtitles. A separate translation window remembers where you placed it."
          )
          item(
            "Capture, read, and reuse",
            icon: "doc.on.clipboard",
            detail: "Zoom into captured text, fit the whole image, and copy or save the full translated image at its original resolution."
          )
        }
      }
      HStack {
        Button("View Full Changelog…") { showsChangelog = true }
        Spacer()
        Button("Done", action: onDone).keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .padding(.top, 16)
    .frame(width: 540, height: 600)
    .sheet(isPresented: $showsChangelog) { BundledDocumentView(document: .changelog) }
  }

  // MARK: Private

  @State private var showsChangelog = false

  private func item(_ title: LocalizedStringResource, icon: String, detail: LocalizedStringResource) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 24)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
