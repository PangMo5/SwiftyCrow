// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText

/// Shared by measurement and drawing. A font matrix reaches Core Text's script
/// fallback faces as well, so emphasis survives translation into CJK scripts
/// whose system families do not have a separate italic face.
enum OverlayTypography {
  static func font(
    size: CGFloat,
    weight: OverlayFontWeight,
    design: OverlayFontDesign,
    isItalic: Bool = false
  ) -> CTFont {
    let base = (design == .monospaced
      ? NSFont.monospacedSystemFont(ofSize: max(1, size), weight: weight.nsFontWeight)
      : NSFont.systemFont(ofSize: max(1, size), weight: weight.nsFontWeight)) as CTFont
    guard isItalic else { return base }
    var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
    return CTFontCreateCopyWithAttributes(base, 0, &matrix, nil)
  }
}
