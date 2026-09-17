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
            Text("Better recognition, clearer translated layouts, and smoother capture and live translation.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          Label("Highlights", systemImage: "sparkles").font(.headline)
          item(
            "Read difficult text more clearly",
            icon: "text.viewfinder",
            detail: "Improved recognition for vertical text, ruby annotations, rotated text, and printed dialogue. Review indicators help you spot uncertain results."
          )
          item(
            "Translations that follow the page",
            icon: "text.alignleft",
            detail: "Keep paragraphs, lists, labels, text styles, and alignment closer to the source. Vertical text is laid out for the language you read."
          )
          item(
            "Capture, inspect, and reuse",
            icon: "doc.on.clipboard",
            detail: "Move the capture window and zoom or pan to inspect text. Copy or save the complete translated image at its original resolution."
          )
          item(
            "Keep reading as the screen changes",
            icon: "waveform",
            detail: "Live translation follows text updates in the selected area. Hide it when you need to, then return to the same area and reading-window position."
          )
          item(
            "Get started in your language",
            icon: "hand.wave",
            detail: "Quick Setup helps with screen access, language downloads, and ⇧⌘1 / ⇧⌘2 shortcuts. The app, website, and guides now support five languages."
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
