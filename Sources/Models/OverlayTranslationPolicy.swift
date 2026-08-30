// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - OverlayTranslationPolicy

enum OverlayTranslationPolicy {

  // MARK: Internal

  /// Preserves code literals and compact metadata cells on the same visual row.
  /// Product names and schema values next to a path are identifiers, while the
  /// surrounding table headers and prose remain natural-language translation.
  static func preservesSource(at index: Int, in sources: [OverlayLine.Source]) -> Bool {
    guard sources.indices.contains(index) else { return false }
    let source = sources[index]
    if source.isProtectedLiteral || source.isProtectedVisualMetadata { return true }
    if isNonlinguisticMetadata(source.text) { return true }
    guard isCompactMetadata(source.text) else { return false }
    return sources.indices.contains { candidate in
      candidate != index
        && sources[candidate].isProtectedLiteral
        && sharesVisualRow(source.box, sources[candidate].box)
    }
  }

  // MARK: Private

  private static func isCompactMetadata(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains("\n"), text.count <= 40 else { return false }
    return text.split(whereSeparator: \.isWhitespace).count <= 4
  }

  private static func isNonlinguisticMetadata(_ text: String) -> Bool {
    let scalars = text.unicodeScalars.filter {
      !CharacterSet.whitespacesAndNewlines.contains($0)
    }
    guard !scalars.isEmpty, scalars.count <= 16 else { return false }
    let letters = scalars.count(where: CharacterSet.letters.contains)
    let digits = scalars.count(where: CharacterSet.decimalDigits.contains)
    return digits > 0 && letters <= 1
  }

  private static func sharesVisualRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    let lhs = lhs.standardized
    let rhs = rhs.standardized
    guard lhs.height > 0, rhs.height > 0 else { return false }
    let overlap = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    if overlap / min(lhs.height, rhs.height) >= 0.45 { return true }
    return abs(lhs.midY - rhs.midY) <= max(lhs.height, rhs.height) * 0.65
  }
}
