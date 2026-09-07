// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Accessibility
import AppKit
import SwiftUI

/// Magnify a single composited image. Hosting the source image, restoration
/// surfaces, and text as separate AppKit layers lets their rasterization diverge
/// during minification, exposing source glyphs behind the translated text.
struct CaptureResultImage: View, Equatable {

  // MARK: Internal

  let imageData: Data?
  let imageSize: CGSize
  let lines: [OverlayLine]

  var body: some View {
    Group {
      if let renderedImage {
        Image(decorative: renderedImage, scale: 1)
          .resizable()
          .overlay {
            // Preserve source-text help and accessibility without adding any
            // visible source or translation layers to the magnified image.
            ForEach(lines) { line in
              Color.clear
                .frame(width: line.source.box.width * imageSize.width, height: line.source.box.height * imageSize.height)
                .contentShape(Rectangle())
                .help(Text(verbatim: line.source.text))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: line.displayedText))
                .position(x: line.source.box.midX * imageSize.width, y: line.source.box.midY * imageSize.height)
            }
          }
      } else if renderFailed {
        Label("Could not render the capture image.", systemImage: "exclamationmark.triangle")
      } else {
        ProgressView()
      }
    }
    .frame(width: imageSize.width, height: imageSize.height)
    .task(id: input) {
      guard !Task.isCancelled else { return }
      let image = Self.render(
        imageData: imageData,
        imageSize: imageSize,
        lines: lines,
        prefersHorizontalTextLayout: prefersHorizontalTextLayout
      )
      renderedImage = image
      renderFailed = image == nil
    }
    .onReceive(NotificationCenter.default
      .publisher(for: AccessibilitySettings.prefersHorizontalTextLayoutDidChangeNotification))
    { _ in
      prefersHorizontalTextLayout = AccessibilitySettings.prefersHorizontalTextLayout
    }
  }

  static func ==(lhs: Self, rhs: Self) -> Bool {
    lhs.imageData == rhs.imageData && lhs.imageSize == rhs.imageSize && lhs.lines == rhs.lines
  }

  /// Shared compositor for preview and export; always runs at source resolution.
  @MainActor
  static func render(
    imageData: Data?,
    imageSize: CGSize,
    lines: [OverlayLine],
    prefersHorizontalTextLayout: Bool? = nil
  ) -> CGImage? {
    guard
      let imageData, let source = NSImage(data: imageData),
      imageSize.width.isFinite, imageSize.height.isFinite,
      imageSize.width > 0, imageSize.height > 0
    else { return nil }
    let renderer = ImageRenderer(content:
      ZStack {
        Image(nsImage: source).resizable()
        TranslationOverlayLayer(lines: lines, prefersHorizontalTextLayout: prefersHorizontalTextLayout)
      }
      .frame(width: imageSize.width, height: imageSize.height)
      .environment(\.displayScale, 1)
    )
    renderer.scale = 1
    return renderer.cgImage
  }

  @MainActor
  static func png(imageData: Data?, imageSize: CGSize, lines: [OverlayLine]) -> Data? {
    render(imageData: imageData, imageSize: imageSize, lines: lines)?.pngData
  }

  // MARK: Private

  private struct Input: Equatable {
    let imageData: Data?
    let imageSize: CGSize
    let lines: [OverlayLine]
    let prefersHorizontalTextLayout: Bool
  }

  @State private var renderedImage: CGImage?
  @State private var renderFailed = false
  @State private var prefersHorizontalTextLayout = AccessibilitySettings.prefersHorizontalTextLayout

  private var input: Input {
    Input(imageData: imageData, imageSize: imageSize, lines: lines, prefersHorizontalTextLayout: prefersHorizontalTextLayout)
  }
}
