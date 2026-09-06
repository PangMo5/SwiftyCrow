// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI

struct CaptureView: View {

  let store: StoreOf<CaptureFeature>

  var body: some View {
    VStack(spacing: 8) {
      Button {
        store.send(.selectRegionRequested)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "viewfinder")
          Text("Capture Region")
        }
        .font(.body.weight(.medium))
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)

      if store.translationUnavailable {
        TranslationModelHint(message: store.lastError)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .transition(.opacity)
      } else if let error = store.lastError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transition(.opacity)
      }
      CaptureStatusNote(lines: store.overlayLines)
    }
    .animation(.easeOut(duration: 0.15), value: store.lastError)
    .animation(.easeOut(duration: 0.15), value: store.translationUnavailable)
  }
}
