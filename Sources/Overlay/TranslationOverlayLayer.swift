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
      ForEach(placements) { placement in
        ForEach(placement.line.source.replacementPatches.indices, id: \.self) { index in
          let patch = placement.line.source.replacementPatches[index]
          let sourceSurface = placement.line.source.surface.flatMap { surface in
            SourcePatchClipping.surface(for: patch, within: surface)
          }
          let frame = OverlayLayoutEngine.replacementFrame(
            for: patch,
            sourceLayout: placement.line.source.layout,
            sourceSurface: sourceSurface,
            in: size,
            displayScale: displayScale
          )
          SourceReplacementSurface(
            appearance: patch.appearance,
            restorationPNG: patch.restorationPNG,
            patchFrame: frame,
            clippingFrame: sourceSurface.map {
              OverlayLayoutEngine.sourceSurfaceFrame(for: $0, in: size)
            },
            cornerRadiusFraction: sourceSurface?.cornerRadiusFraction ?? 0,
            clippingRows: sourceSurface?.clippingRows.map {
              CGRect(
                x: $0.minX * size.width,
                y: $0.minY * size.height,
                width: $0.width * size.width,
                height: $0.height * size.height
              )
            } ?? []
          )
          .equatable()
        }
      }
      ForEach(placements) { placement in
        ReplacementText(placement: placement)
          .equatable()
          .help(Text(verbatim: placement.line.source.text))
          .frame(width: placement.frame.width, height: placement.frame.height)
          .clipped()
          .rotationEffect(.radians(placement.rotationRadians))
          .position(x: placement.frame.midX, y: placement.frame.midY)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .clipped()
    .mask {
      Canvas { context, _ in
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
        var protected = Path()
        for frame in OverlayLayoutEngine.protectedSourceFrames(
          for: lines,
          placements: placements,
          in: size,
          displayScale: displayScale
        ) {
          protected.addRect(frame)
        }
        context.blendMode = .destinationOut
        context.fill(protected, with: .color(.white))
      }
    }
  }

  static func ==(lhs: Self, rhs: Self) -> Bool {
    lhs.lines == rhs.lines && lhs.size == rhs.size
      && lhs.prefersHorizontalTextLayout == rhs.prefersHorizontalTextLayout
  }

  // MARK: Private

  @Environment(\.displayScale) private var displayScale

}

// MARK: - SourceReplacementSurface

private struct SourceReplacementSurface: View, Equatable {

  // MARK: Internal

  let appearance: OverlaySourceAppearance
  let restorationPNG: Data?
  let patchFrame: CGRect
  let clippingFrame: CGRect?
  let cornerRadiusFraction: CGFloat
  let clippingRows: [CGRect]

  var body: some View {
    if let clippingFrame, !clippingFrame.isEmpty {
      ZStack(alignment: .topLeading) {
        restoredSurface
          .frame(width: patchFrame.width, height: patchFrame.height)
          .offset(
            x: patchFrame.minX - clippingFrame.minX,
            y: patchFrame.minY - clippingFrame.minY
          )
      }
      .frame(
        width: clippingFrame.width,
        height: clippingFrame.height,
        alignment: .topLeading
      )
      .clipShape(SourceSurfaceClip(
        rows: clippingRows.map { $0.offsetBy(dx: -clippingFrame.minX, dy: -clippingFrame.minY) },
        cornerRadius: min(clippingFrame.width, clippingFrame.height) * cornerRadiusFraction
      ))
      .position(x: clippingFrame.midX, y: clippingFrame.midY)
    } else {
      restoredSurface
        .frame(width: patchFrame.width, height: patchFrame.height)
        .position(x: patchFrame.midX, y: patchFrame.midY)
    }
  }

  // MARK: Private

  @ViewBuilder
  private var restoredSurface: some View {
    if let restorationPNG, let image = NSImage(data: restorationPNG) {
      Image(nsImage: image).resizable()
    } else {
      Rectangle().fill(Color(appearance.background))
    }
  }

}

// MARK: - SourceSurfaceClip

private struct SourceSurfaceClip: Shape {
  let rows: [CGRect]
  let cornerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    guard !rows.isEmpty else {
      return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
    }
    var path = Path()
    path.addRects(rows)
    return path
  }
}

// MARK: - ReplacementText

private struct ReplacementText: View, Equatable {

  // MARK: Internal

  let placement: OverlayPlacement

  var body: some View {
    switch placement.flow {
    case .horizontal:
      Group {
        if let image = HorizontalTextRenderer.image(for: placement, scale: displayScale) {
          Image(decorative: image, scale: displayScale)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: placement.line.displayedText))

    case .vertical(let progression):
      VerticalOverlayText(
        text: placement.line.displayedText,
        language: placement.line.displayedLanguage,
        fontSize: placement.fontSize,
        fontWeight: placement.line.source.appearance.fontWeight,
        fontDesign: placement.line.source.appearance.fontDesign,
        progression: progression,
        wrapping: placement.verticalWrapping,
        foreground: placement.line.source.appearance.foreground,
        baseBackground: placement.line.source.appearance.background,
        styles: placement.line.displayedStyleRuns,
        isUnderlined: placement.line.source.appearance.isUnderlined
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: placement.line.displayedText))
    }
  }

  static func ==(lhs: Self, rhs: Self) -> Bool {
    lhs.placement == rhs.placement
  }

  // MARK: Private

  @Environment(\.displayScale) private var displayScale
}

// MARK: - VerticalOverlayText

private struct VerticalOverlayText: View {

  // MARK: Internal

  let text: String
  let language: Locale.Language
  let fontSize: CGFloat
  let fontWeight: OverlayFontWeight
  let fontDesign: OverlayFontDesign
  let progression: OverlayColumnProgression
  let wrapping: CoreTextTypesetter.VerticalWrapping
  let foreground: OverlayColor
  let baseBackground: OverlayColor
  let styles: [OverlayTextStyleRun]
  let isUnderlined: Bool

  var body: some View {
    GeometryReader { proxy in
      if
        let image = CoreTextTypesetter.verticalGlyphImage(
          text: text,
          language: language,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontDesign: fontDesign,
          size: proxy.size,
          scale: displayScale,
          progression: progression,
          wrapping: wrapping,
          foreground: foreground,
          baseBackground: baseBackground,
          styles: styles,
          isUnderlined: isUnderlined
        )
      {
        Image(decorative: image, scale: displayScale)
          .renderingMode(.original)
          .resizable()
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .environment(\.locale, Locale(identifier: language.maximalIdentifier))
  }

  // MARK: Private

  @Environment(\.displayScale) private var displayScale
}

extension Color {
  fileprivate init(_ color: OverlayColor) {
    self.init(
      red: Double(color.red),
      green: Double(color.green),
      blue: Double(color.blue),
      opacity: Double(color.alpha)
    )
  }
}
