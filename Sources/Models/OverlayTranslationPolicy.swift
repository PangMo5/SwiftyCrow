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
    if
      source.text.count == 1, source.text.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }),
      source.language.script?.identifier != "Latn" { return true }
    if source.isProtectedLiteral || source.isProtectedVisualMetadata { return true }
    if isNonlinguisticMetadata(source.text) || OCRTextSemantics.isVersionedProductName(source.text) {
      return true
    }
    let words = source.text.split(whereSeparator: \.isWhitespace)
    guard
      case .horizontal = source.layout,
      isCompactMetadata(source.text),
      words.count == 1 || words.allSatisfy({ $0.first?.isUppercase == true })
    else { return false }
    return sources.indices.contains { candidate in
      guard candidate != index, case .horizontal = sources[candidate].layout else { return false }
      return sources[candidate].recognitionContextID == source.recognitionContextID
        && sources[candidate].isProtectedLiteral
        && !OCRTextSemantics.isIdentifier(sources[candidate].text)
        // Measured fixed pitch protects the token itself, not unrelated prose
        // sharing its baseline. Metadata propagation needs explicit code syntax
        // and a local label/value gap, never a distant sidebar/table column.
        && sources[candidate].text.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace })
        && (sources[candidate].box.minX - source.box.maxX) * source.imageAspectRatio
        <= max(source.box.height, sources[candidate].box.height) * 4
        // Table metadata labels precede their literal value. Trailing controls
        // such as Copy beside a command are actions and still need translation.
        && source.box.maxX <= sources[candidate].box.minX
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
    guard case .horizontal = source.layout, isCompactMetadata(source.text) else { return nil }
    if let rhythm = phoneticCluster(at: index, in: sources) { return rhythm }

    let rowValues = sources.indices.filter { candidate in
      guard candidate != index, case .horizontal = sources[candidate].layout else { return false }
      return sources[candidate].recognitionContextID == source.recognitionContextID
        && isContextValue(sources[candidate])
        && sharesVisualRow(source.box, sources[candidate].box)
    }
    // One nearby number can be ordinary prose. Repeated compact values on the
    // same row are the structural signal for a badge/segmented-control run.
    let explicitLabel = source.text.hasSuffix(":") || source.text.split(whereSeparator: \.isWhitespace).count == 1
    if rowValues.count >= 2 || explicitLabel {
      let value = rowValues.compactMap { candidate -> (gap: CGFloat, text: String)? in
        let value = sources[candidate]
        let labelBox = source.box.standardized
        let valueBox = value.box.standardized
        let gap = (valueBox.minX - labelBox.maxX) * source.imageAspectRatio
        guard
          gap >= -max(labelBox.height, valueBox.height) * 0.1,
          gap <= max(labelBox.height, valueBox.height) * 2
        else { return nil }
        return (gap, value.text.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      .min(by: { $0.gap < $1.gap })?
      .text
      if let value { return value }
    }

    // Independent navigation items need their visual context without becoming
    // one translated sentence. A nearby technical acronym disambiguates nouns
    // such as "License" while each item retains its own frame and response.
    let peers = sources.indices.filter {
      guard $0 != index, case .horizontal = sources[$0].layout else { return false }
      return sources[$0].recognitionContextID == source.recognitionContextID
        && isCompactMetadata(sources[$0].text)
        && sharesVisualRow(source.box, sources[$0].box)
    }
    if
      peers.count >= 3,
      let context = peers.map({ sources[$0].text }).first(where: { text in
        (2 ... 8).contains(text.count) && !OCRTextSemantics.isIdentifier(text)
          && text.unicodeScalars.allSatisfy { (0x41 ... 0x5A).contains($0.value) }
      })
    {
      return context
    }

    let labels = peers.filter { candidate in
      let peer = sources[candidate]
      guard
        !peer.isProtectedLiteral, peer.language.usesSameWritingSystem(as: source.language),
        source.text.split(whereSeparator: \.isWhitespace).count <= 3,
        peer.text.split(whereSeparator: \.isWhitespace).count <= 3,
        !peer.text.contains(where: { ".:!?".contains($0) }),
        peer.text.contains(where: \.isLetter),
        case .horizontal(rows: 1) = peer.layout,
        case .horizontal(rows: 1) = source.layout
      else { return false }
      let a = source.box
      let b = peer.box
      guard
        min(a.height, b.height) / max(a.height, b.height) >= 0.65,
        abs(a.midY - b.midY) <= min(a.height, b.height) * 0.5
      else { return false }
      let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
      let characterWidth = min(a.width / CGFloat(max(1, source.text.count)), b.width / CGFloat(max(1, peer.text.count)))
      return gap >= characterWidth * 1.5
    }
    if labels.count >= 3 {
      return labels.sorted { sources[$0].box.minX < sources[$1].box.minX }
        .prefix(4).map { sources[$0].text }.joined(separator: " / ")
    }

    // A lone link/card heading can otherwise be translated as an unrelated
    // dictionary sense. Its enclosing page heading supplies existing context.
    if
      source.text.split(whereSeparator: \.isWhitespace).count == 1,
      source.text.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
      source.appearance.fontSizeScale > 0
    {
      let heading = sources.enumerated().filter { candidate, value in
        candidate != index && value.recognitionContextID == source.recognitionContextID && !value.isProtectedLiteral
          && value.language.usesSameWritingSystem(as: source.language)
          && value.text.count <= 100 && !value.text.contains(":") && !value.text.contains("：")
          && value.box.maxY < source.box.minY
          && source.box.minY - value.box.maxY <= source.box.height * 8
          && min(source.box.maxX, value.box.maxX) > max(source.box.minX, value.box.minX)
          && value.appearance.fontSizeScale >= source.appearance.fontSizeScale * 1.2
      }.max { $0.element.box.maxY < $1.element.box.maxY }?.element
      if let heading { return heading.text }
    }

    return nil
  }

  // MARK: Private

  /// Repeated, tilted phonetic words form a sound sequence rather than an
  /// isolated proper name. Context is translation-only; each frame stays owned
  /// by its original word, including different rotations within the sequence.
  private static func phoneticCluster(at index: Int, in sources: [OverlayLine.Source]) -> String? {
    let candidates = sources.indices.filter { candidate in
      let value = sources[candidate]
      guard case .horizontal(rows: 1) = value.layout else { return false }
      return !value.isProtectedLiteral && !value.preservesSource && (2...6).contains(value.text.count)
        && value.text.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
        && value.recognitionContextID == sources[index].recognitionContextID
        && value.language.maximalIdentifier == sources[index].language.maximalIdentifier
    }
    guard candidates.contains(index) else { return nil }
    var group = [index]
    var seen: Set<Int> = [index]
    var cursor = 0
    while cursor < group.count, group.count < 8 {
      let a = sources[group[cursor]]
      cursor += 1
      for other in candidates where !seen.contains(other) {
        let b = sources[other]
        let height = max(a.box.height, b.box.height)
        let dx = max(0, max(a.box.minX - b.box.maxX, b.box.minX - a.box.maxX)) * a.imageAspectRatio
        let dy = max(0, max(a.box.minY - b.box.maxY, b.box.minY - a.box.maxY))
        if
          dx <= height, dy <= height, min(a.box.height, b.box.height) >= height * 0.55,
          a.appearance.background.distance(to: b.appearance.background) <= 0.06
        {
          seen.insert(other)
          group.append(other)
        }
      }
    }
    guard
      group.count >= 3, group.contains(where: { abs(sources[$0].rotationRadians) > 0.04 }),
      Set(group.map { sources[$0].text }).count >= 2
    else { return nil }
    return group.sorted { sources[$0].box.minY < sources[$1].box.minY }.map { sources[$0].text }.joined(separator: "、")
  }

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
    // Circled digits, fractions and Roman numeral symbols carry numeric
    // meaning too. Translating them discards their original visual form.
    let digits = scalars.count { $0.properties.numericType != nil }
    return digits > 0 && letters <= 1
  }

  private static func isContextValue(_ source: OverlayLine.Source) -> Bool {
    guard source.text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return false }
    return source.isProtectedLiteral
      || source.isProtectedVisualMetadata
      || isNonlinguisticMetadata(source.text)
      || OCRTextSemantics.isVersionedProductName(source.text)
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
