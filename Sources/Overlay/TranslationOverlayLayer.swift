// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Accessibility
import AppKit
import SwiftUI

// MARK: - TranslationOverlayLayer

/// Draws locale-aware translated text over its OCR source region. Geometry is
/// resolved as one scene so every translation stays inside its original visual
/// container. Vision's word/line regions are restored before replacement text
/// is drawn, preserving nearby borders and artwork.
struct TranslationOverlayLayer: View {

  // MARK: Lifecycle

  init(
    lines: [OverlayLine],
    prefersHorizontalTextLayout preferenceOverride: Bool? = nil
  ) {
    self.lines = lines
    followsSystemHorizontalTextPreference = preferenceOverride == nil
    _prefersHorizontalTextLayout = State(
      initialValue: preferenceOverride ?? AccessibilitySettings.prefersHorizontalTextLayout
    )
  }

  // MARK: Internal

  let lines: [OverlayLine]

  var body: some View {
    GeometryReader { proxy in
      OverlayCanvas(
        lines: lines,
        size: proxy.size,
        prefersHorizontalTextLayout: prefersHorizontalTextLayout
      )
      .equatable()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AccessibilitySettings.prefersHorizontalTextLayoutDidChangeNotification
      )
    ) { _ in
      guard followsSystemHorizontalTextPreference else { return }
      prefersHorizontalTextLayout = AccessibilitySettings.prefersHorizontalTextLayout
    }
  }

  // MARK: Private

  @State private var prefersHorizontalTextLayout: Bool

  private let followsSystemHorizontalTextPreference: Bool

}

// MARK: - OverlayCanvas

private struct OverlayCanvas: View, Equatable {

  // MARK: Internal

  let lines: [OverlayLine]
  let size: CGSize
  let prefersHorizontalTextLayout: Bool

  var body: some View {
    let placements = OverlayLayoutEngine.placements(
      for: lines,
      in: size,
      prefersHorizontalTextLayout: prefersHorizontalTextLayout
    )
    ZStack(alignment: .topLeading) {
      if
        let image = OverlayRasterRenderer.render(
          lines: lines,
          size: size,
          scale: displayScale,
          prefersHorizontalTextLayout: prefersHorizontalTextLayout
        )
      {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .frame(width: size.width, height: size.height)
      } else if size.width > 0, size.height > 0 {
        Text("Could not render the capture image. Please try again.")
      }
      ForEach(placements) { placement in
        Color.clear
          .frame(width: placement.frame.width, height: placement.frame.height)
          .rotationEffect(.radians(placement.rotationRadians))
          .position(x: placement.frame.midX, y: placement.frame.midY)
          .help(Text(verbatim: placement.line.source.text))
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text(verbatim: placement.line.displayedText))
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .clipped()
  }

  static func ==(lhs: Self, rhs: Self) -> Bool {
    lhs.lines == rhs.lines && lhs.size == rhs.size
      && lhs.prefersHorizontalTextLayout == rhs.prefersHorizontalTextLayout
  }

  // MARK: Private

  @Environment(\.displayScale) private var displayScale

}
