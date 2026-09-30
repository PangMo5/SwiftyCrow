// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A visual group translated as one semantic unit. Only provider-owned label
/// ranges may return to the individual overlay frames; the topic is not shown.
struct TranslationGroupContext: Hashable, Sendable {

  // MARK: Internal

  struct Member: Hashable, Sendable {
    var context: TranslationGroupContext
    var index: Int
  }

  var topic: String
  var labels: [String]

  var attributedRequest: AttributedString? {
    guard
      !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, topic.count <= 120,
      !topic.contains(where: { ";；؛\n\r".contains($0) }), (2...12).contains(labels.count),
      labels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 40
          && !$0.contains(where: { ":：;；؛\n\r".contains($0) }) })
    else { return nil }
    var result = AttributedString(topic + ": ")
    for (index, label) in labels.enumerated() {
      if index > 0 { result += AttributedString("; ") }
      var value = AttributedString(label)
      value.link = Self.link(index)
      result += value
    }
    return result
  }

  /// Use observed grid ownership and a nearby caption, not vocabulary-specific
  /// replacements. Tables from different recognition contexts cannot mix.
  static func tableHeaders(in sources: [OverlayLine.Source]) -> [Int: Member] {
    struct Table: Hashable {
      var context: Int?
      var table: Int
    }
    let indices = sources.indices.filter { sources[$0].tableCell != nil }
    let tables = Dictionary(grouping: indices) { Table(
      context: sources[$0].recognitionContextID,
      table: sources[$0].tableCell!.table
    ) }
    var result = [Int: Member]()
    for members in tables.values {
      guard let firstRow = members.compactMap({ sources[$0].tableCell?.row }).min() else { continue }
      let headers = members.filter { index in
        let source = sources[index]
        guard
          let cell = source.tableCell, cell.row == firstRow, cell.rowSpan == 1, cell.columnSpan == 1,
          case .horizontal(rows: 1) = source.layout,
          !source.preservesSource, !source.isProtectedLiteral, source.text.contains(where: \.isLetter),
          source.appearance.fontWeight.rawValue >= OverlayFontWeight.medium.rawValue,
          TranslationLiteralPlan(source.attributedTextForTranslation()) == nil
        else { return false }
        return true
      }.sorted { sources[$0].tableCell!.column < sources[$1].tableCell!.column }
      guard
        headers.count >= 2,
        headers.count == members.count(where: { sources[$0].tableCell!.row == firstRow }),
        Set(headers.map { sources[$0].tableCell!.column }).count == headers.count,
        headers.allSatisfy({ sources[$0].language.maximalIdentifier == sources[headers[0]].language.maximalIdentifier })
      else { continue }
      let columns = Set(headers.map { sources[$0].tableCell!.column })
      let bodyRows = Dictionary(grouping: members.filter { sources[$0].tableCell!.row > firstRow }) { sources[$0].tableCell!.row }
      guard bodyRows.values.count(where: { Set($0.map { sources[$0].tableCell!.column }).intersection(columns).count >= 2 }) >= 2
      else { continue }
      let headerBounds = headers.reduce(CGRect.null) { $0.union(sources[$1].tableCell!.box) }
      let height = headers.map { sources[$0].box.height }.max() ?? 0
      guard height > 0 else { continue }
      let caption = sources.enumerated().filter { index, source in
        guard
          !members.contains(index), source.tableCell == nil,
          source.recognitionContextID == sources[headers[0]].recognitionContextID,
          !source.preservesSource, !source.isProtectedLiteral,
          source.language.maximalIdentifier == sources[headers[0]].language.maximalIdentifier,
          case .horizontal(rows: 1) = source.layout,
          source.text.count >= 4, source.text.count <= 120, source.text.contains(where: \.isLetter),
          source.box.height <= height * 1.4, source.box.maxY <= headerBounds.minY,
          headerBounds.minY - source.box.maxY <= height * 4,
          min(source.box.maxX, headerBounds.maxX) > max(source.box.minX, headerBounds.minX)
        else { return false }
        return true
      }.max { $0.element.box.maxY < $1.element.box.maxY }?.element
      guard let caption else { continue }
      let context = Self(topic: caption.text, labels: headers.map { sources[$0].text })
      guard context.attributedRequest != nil else { continue }
      for (index, sourceIndex) in headers.enumerated() { result[sourceIndex] = Member(context: context, index: index) }
    }
    return result
  }

  func targets(from response: AttributedString?) -> [String]? {
    guard
      attributedRequest != nil, let response,
      let separator = response.characters.lastIndex(where: { ":：".contains($0) })
    else { return nil }
    let characters = response.characters
    let start = characters.index(after: separator)
    let links = Dictionary(uniqueKeysWithValues: labels.indices.map { (Self.link($0), $0) })
    // A missing/moved separator must not discard a provider-linked label.
    guard response[..<start].runs.allSatisfy({ $0.link.flatMap { links[$0] } == nil }) else { return nil }
    var pieces = [Range<AttributedString.Index>]()
    var lower = start
    for index in characters[start...].indices where ";；؛".contains(characters[index]) {
      pieces.append(lower..<index)
      lower = characters.index(after: index)
    }
    pieces.append(lower..<characters.endIndex)
    guard pieces.count == labels.count else { return nil }
    var result = [Int: String]()
    for piece in pieces {
      var lower = piece.lowerBound
      var upper = piece.upperBound
      while lower < upper, characters[lower].isWhitespace { lower = characters.index(after: lower) }
      while lower < upper, characters[characters.index(before: upper)].isWhitespace { upper = characters.index(before: upper) }
      guard lower < upper else { return nil }
      let runs = response[lower..<upper].runs
      let owners = Set(runs.compactMap(\.link))
      guard
        owners.count == 1, let owner = owners.first, let index = links[owner], result[index] == nil,
        runs.allSatisfy({ run in
          run.link == owner || characters[run.range].allSatisfy { $0.isWhitespace || $0.isPunctuation }
        })
      else { return nil }
      let text = String(characters[lower..<upper])
      guard !text.contains("\u{FFFD}"), !text.contains(where: \.isNewline) else { return nil }
      result[index] = text
    }
    guard result.count == labels.count else { return nil }
    return labels.indices.compactMap { result[$0] }
  }

  // MARK: Private

  private static func link(_ index: Int) -> URL {
    URL(string: "swiftycrow-context://item/\(index)")!
  }
}
