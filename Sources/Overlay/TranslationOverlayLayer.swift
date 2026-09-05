// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Accessibility
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
            surface.confidence >= 0.35 ? surface : nil
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
          .frame(width: placement.frame.width, height: placement.frame.height)
          .clipped()
          .position(x: placement.frame.midX, y: placement.frame.midY)
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

// MARK: - SourceReplacementSurface

private struct SourceReplacementSurface: View, Equatable {

  let appearance: OverlaySourceAppearance
  let patchFrame: CGRect
  let clippingFrame: CGRect?
  let cornerRadiusFraction: CGFloat
  let clippingRows: [CGRect]

  var body: some View {
    if let clippingFrame, !clippingFrame.isEmpty {
      ZStack(alignment: .topLeading) {
        Rectangle()
          .fill(Color(appearance.background))
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
      Rectangle()
        .fill(Color(appearance.background))
        .frame(width: patchFrame.width, height: patchFrame.height)
        .position(x: patchFrame.midX, y: patchFrame.midY)
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

  let placement: OverlayPlacement

  var body: some View {
    switch placement.flow {
    case .horizontal(let direction):
      HorizontalOverlayText(
        text: placement.line.displayedText,
        language: placement.line.displayedLanguage,
        fontSize: placement.fontSize,
        lineHeightMultiple: placement.lineHeightMultiple,
        appearance: placement.line.source.appearance,
        styleRuns: placement.line.displayedStyleRuns,
        lineLimit: placement.lineLimit,
        direction: direction,
        alignment: placement.alignment,
        sourceLayout: placement.line.source.layout
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: placement.line.displayedText))

    case .vertical(let progression):
      VerticalOverlayText(
        text: placement.line.displayedText,
        language: placement.line.displayedLanguage,
        fontSize: placement.fontSize,
        fontWeight: placement.line.source.appearance.fontWeight,
        fontDesign: placement.line.source.appearance.fontDesign,
        progression: progression
      )
      .foregroundStyle(Color(placement.line.source.appearance.foreground))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: placement.line.displayedText))
    }
  }
}

// MARK: - HorizontalOverlayText

private struct HorizontalOverlayText: View, Equatable {

  // MARK: Internal

  let text: String
  let language: Locale.Language
  let fontSize: CGFloat
  let lineHeightMultiple: CGFloat
  let appearance: OverlaySourceAppearance
  let styleRuns: [OverlayTextStyleRun]
  let lineLimit: Int?
  let direction: OverlayInlineDirection
  let alignment: OverlayTextAlignment
  let sourceLayout: OverlaySourceLayout

  var body: some View {
    Text(styledText)
      .font(.system(
        size: fontSize,
        weight: appearance.fontWeight.swiftUIWeight,
        design: appearance.fontDesign.swiftUIFontDesign
      ))
      .foregroundStyle(Color(appearance.foreground))
      .multilineTextAlignment(textAlignment)
      .lineSpacing(CoreTextTypesetter.lineSpacing(
        fontSize: fontSize,
        language: language,
        fontWeight: appearance.fontWeight,
        fontDesign: appearance.fontDesign,
        lineHeightMultiple: lineHeightMultiple
      ))
      .lineLimit(lineLimit)
      .truncationMode(.tail)
      .minimumScaleFactor(0.78)
      .allowsTightening(true)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
      .environment(\.locale, Locale(identifier: language.maximalIdentifier))
      .environment(\.layoutDirection, direction == .rightToLeft ? .rightToLeft : .leftToRight)
  }

  // MARK: Private

  private var styledText: AttributedString {
    var attributed = AttributedString(text)
    for run in styleRuns {
      guard
        let stringRange = Range(run.range, in: text),
        let lowerBound = AttributedString.Index(stringRange.lowerBound, within: attributed),
        let upperBound = AttributedString.Index(stringRange.upperBound, within: attributed)
      else { continue }
      let range = lowerBound ..< upperBound
      attributed[range].font = .system(
        size: fontSize,
        weight: run.appearance.fontWeight.swiftUIWeight,
        design: run.appearance.fontDesign.swiftUIFontDesign
      )
      attributed[range].foregroundColor = Color(run.appearance.foreground)
      if run.appearance.background.distance(to: appearance.background) >= 0.025 {
        attributed[range].backgroundColor = Color(run.appearance.background)
      }
      if run.appearance.isUnderlined {
        attributed[range].underlineStyle = .single
      }
    }
    return attributed
  }

  private var textAlignment: TextAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private var frameAlignment: Alignment {
    switch (sourceLayout, alignment) {
    // Vision includes ascenders, furigana, and line-leading in its source box.
    // Centering on that original box keeps a shorter translation on the same
    // visual baseline instead of pinning it against the top border.
    case (.horizontal, .leading): .leading
    case (.horizontal, .center): .center
    case (.horizontal, .trailing): .trailing
    case (.vertical, .leading): .leading
    case (.vertical, .center): .center
    case (.vertical, .trailing): .trailing
    }
  }
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
          progression: progression
        )
      {
        Image(decorative: image, scale: displayScale)
          .renderingMode(.template)
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

extension OverlayFontWeight {
  fileprivate var swiftUIWeight: Font.Weight {
    switch self {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    }
  }
}

extension OverlayFontDesign {
  fileprivate var swiftUIFontDesign: Font.Design {
    switch self {
    case .standard: .default
    case .monospaced: .monospaced
    }
  }
}

extension OverlayColor {
  fileprivate func distance(to other: OverlayColor) -> CGFloat {
    max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
  }
}
