// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

// MARK: - OverlayColor

struct OverlayColor: Equatable, Hashable, Sendable {
  static let black = OverlayColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
  static let white = OverlayColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)

  var red: CGFloat
  var green: CGFloat
  var blue: CGFloat
  var alpha: CGFloat

}

// MARK: - OverlayFontWeight

enum OverlayFontWeight: Int, CaseIterable, Equatable, Hashable, Sendable {
  case regular
  case medium
  case semibold
  case bold
}

// MARK: - OverlayFontDesign

enum OverlayFontDesign: Int, Equatable, Hashable, Sendable {
  case standard
  case monospaced
}

// MARK: - OverlaySourceAppearance

struct OverlaySourceAppearance: Equatable, Hashable, Sendable {
  static let fallback = OverlaySourceAppearance(
    background: .white,
    foreground: .black,
    confidence: 0
  )

  var background: OverlayColor
  var foreground: OverlayColor
  /// Share of sampled pixels represented by the dominant background cluster.
  /// It is diagnostic data, not a rendering-style switch.
  var confidence: CGFloat
  /// Composited source-glyph color sampled from the original pixels.
  var foregroundConfidence: CGFloat = 0
  /// Ink coverage inside Vision's line box, used to approximate source weight.
  var inkCoverage: CGFloat = 0
  /// Height of the high-contrast source ink, normalized to the image. Unlike a
  /// Vision line/word box this excludes surrounding icon and control padding.
  var inkHeightScale: CGFloat = 0
  var fontWeight = OverlayFontWeight.semibold
  var fontDesign = OverlayFontDesign.standard
  var isUnderlined = false

}

// MARK: - OverlaySourceStyleRun

/// Appearance and geometry for one source word. The UTF-16 range is retained
/// so Apple Translation can align the style with its translated counterpart.
struct OverlaySourceStyleRun: Equatable, Hashable, Sendable {
  var range: NSRange
  var box: CGRect
  var appearance = OverlaySourceAppearance.fallback
}

// MARK: - OverlayTextStyleRun

/// A source style mapped onto a translated UTF-16 range by Apple Translation.
struct OverlayTextStyleRun: Equatable, Hashable, Sendable {
  var range: NSRange
  var appearance: OverlaySourceAppearance
}

// MARK: - OverlaySourcePatch

/// A Vision-provided word or line region that contains source glyphs to erase.
/// Keeping these regions separate from the paragraph bounds avoids painting
/// over nearby speech-bubble borders and artwork.
struct OverlaySourcePatch: Equatable, Hashable, Sendable {
  var box: CGRect
  var appearance = OverlaySourceAppearance.fallback
  /// True when this patch removes a compact styled surface embedded inside a
  /// larger sentence, such as the old position of an inline-code pill. These
  /// patches must survive flat-row consolidation.
  var erasesDistinctSurface = false
}

// MARK: - OverlaySourceSurface

/// A flat, closed source region such as a speech bubble or text panel. The
/// renderer may reflow translated text inside this box without crossing the
/// visual container inferred from the original pixels.
struct OverlaySourceSurface: Equatable, Hashable, Sendable {
  /// Inset bounds available to translated text.
  var box: CGRect
  var confidence: CGFloat
  /// Full detected interior used to clip source-erasure patches. Keeping this
  /// separate from `box` prevents the text safety inset from leaving glyphs
  /// behind near a curved speech-balloon edge.
  var clippingBox: CGRect? = nil
  /// Corner radius relative to the surface's shorter side. Pixel flood-fill
  /// distinguishes balloons and pills from rectangular UI surfaces.
  var cornerRadiusFraction: CGFloat = 0
}
