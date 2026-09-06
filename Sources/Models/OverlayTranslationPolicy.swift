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
    if isNonlinguisticMetadata(source.text) || isVersionedTechnicalMetadata(source.text) {
      return true
    }
    guard isCompactMetadata(source.text) else { return false }
    return sources.indices.contains { candidate in
      candidate != index
        && sources[candidate].isProtectedLiteral
        && !OCRTextSemantics.isIdentifier(sources[candidate].text)
        && sharesVisualRow(source.box, sources[candidate].box)
    }
  }

  /// Supplies a compact trailing value as translation-only context for its
  /// leading label. The label and value remain independent visual regions, but
  /// `release: v1.12.0` disambiguates the UI noun from the verb "release" while
  /// the version itself keeps its original pixels.
  static func trailingContext(at index: Int, in sources: [OverlayLine.Source]) -> String? {
    guard sources.indices.contains(index), !preservesSource(at: index, in: sources) else {
      return nil
    }
    let source = sources[index]
    guard isCompactMetadata(source.text) else { return nil }

    let rowValues = sources.indices.filter { candidate in
      candidate != index
        && isContextValue(sources[candidate])
        && sharesVisualRow(source.box, sources[candidate].box)
    }
    // One nearby number can be ordinary prose. Repeated compact values on the
    // same row are the structural signal for a badge/segmented-control run.
    let explicitLabel = source.text.hasSuffix(":") || source.text.split(whereSeparator: \.isWhitespace).count == 1
    guard rowValues.count >= 2 || explicitLabel else { return nil }

    return rowValues.compactMap { candidate -> (gap: CGFloat, text: String)? in
      let value = sources[candidate]
      let labelBox = source.box.standardized
      let valueBox = value.box.standardized
      let gap = valueBox.minX - labelBox.maxX
      guard
        gap >= -max(labelBox.height, valueBox.height) * 0.1,
        gap <= max(labelBox.height, valueBox.height) * 2
      else { return nil }
      return (gap, value.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    .min(by: { $0.gap < $1.gap })?
    .text
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

  private static func isVersionedTechnicalMetadata(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !text.isEmpty,
      !text.contains("\n"),
      text.count <= 40,
      text.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
    else { return false }

    let words = text.split(whereSeparator: \.isWhitespace)
    guard
      let first = words.first,
      words.dropFirst().allSatisfy({ $0.range(of: #"^v?\d\S*$"#, options: .regularExpression) != nil })
    else { return false }
    let letters = first.unicodeScalars.filter(CharacterSet.letters.contains)
    guard
      letters.count >= 2,
      letters.allSatisfy({ (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) })
    else { return false }
    let upper = letters.count { (0x41...0x5A).contains($0.value) }
    return upper == letters.count || upper >= 2
  }

  private static func isContextValue(_ source: OverlayLine.Source) -> Bool {
    guard source.text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return false }
    return source.isProtectedLiteral
      || source.isProtectedVisualMetadata
      || isNonlinguisticMetadata(source.text)
      || isVersionedTechnicalMetadata(source.text)
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
