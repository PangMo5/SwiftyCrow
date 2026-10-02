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

  static func associations(in sources: [OverlayLine.Source]) -> [Int: Member] {
    var result = tableHeaders(in: sources)
    for groups in [tableColumnValues(in: sources), alignedLabels(in: sources)] {
      for (index, member) in groups where result[index] == nil { result[index] = member }
    }
    return result
  }

  /// Native cell ownership supplies the column's meaning even when its caption
  /// is too far away to establish a whole-table context. Repeated values retain
  /// separate attributed owners; paths, numbers and merged cells stay literal.
  static func tableColumnValues(in sources: [OverlayLine.Source]) -> [Int: Member] {
    struct Column: Hashable { var context: Int?
      var table: Int
      var column: Int
    }
    let columns = Dictionary(grouping: sources.indices.filter { sources[$0].tableCell != nil }) {
      Column(
        context: sources[$0].recognitionContextID,
        table: sources[$0].tableCell!.table,
        column: sources[$0].tableCell!.column
      )
    }
    var result = [Int: Member]()
    for indices in columns.values {
      let ordered = indices.sorted { sources[$0].tableCell!.row < sources[$1].tableCell!.row }
      guard
        let header = ordered.first, let cell = sources[header].tableCell,
        cell.row == 0, cell.rowSpan == 1, cell.columnSpan == 1,
        sources[header].appearance.fontWeight.rawValue >= OverlayFontWeight.medium.rawValue,
        isLabel(sources[header])
      else { continue }
      let members = ordered.dropFirst().filter {
        let source = sources[$0]
        return source.tableCell!.rowSpan == 1 && source.tableCell!.columnSpan == 1
          && source.language.maximalIdentifier == sources[header].language.maximalIdentifier && isLabel(source)
      }
      for start in stride(from: 0, to: members.count, by: 12) {
        let batch = Array(members.dropFirst(start).prefix(12))
        assign(batch, topic: sources[header].text, sources: sources, to: &result)
      }
    }
    return result
  }

  /// Related short labels share an observed column, spacing, script and surface.
  /// Translate their neighborhood together while keeping every original frame.
  /// A nearby heading adds context; no vocabulary identifies menus or actions.
  static func alignedLabels(in sources: [OverlayLine.Source]) -> [Int: Member] {
    struct Table: Hashable {
      var context: Int?
      var table: Int
    }
    let tables = Dictionary(grouping: sources.indices.filter { sources[$0].tableCell != nil }) {
      Table(context: sources[$0].recognitionContextID, table: sources[$0].tableCell!.table)
    }
    let listTables = Set(tables.compactMap { table, members -> Table? in
      let columns = Set(members.map { sources[$0].tableCell!.column })
      return columns.count == 1 && members.allSatisfy { sources[$0].tableCell!.columnSpan == 1 } ? table : nil
    })
    let candidates = sources.indices.filter {
      let source = sources[$0]
      let isList = source.tableCell.map {
        listTables.contains(Table(context: source.recognitionContextID, table: $0.table))
      } ?? true
      return source.recognitionContextID != nil && isList && isLabel(source)
    }
    var remaining = Set(candidates)
    var result = [Int: Member]()
    while let seed = remaining.min() {
      remaining.remove(seed)
      var group = [seed]
      var cursor = 0
      while cursor < group.count {
        let neighbors = remaining.filter { aligned(sources[group[cursor]], sources[$0]) }
        remaining.subtract(neighbors)
        group.append(contentsOf: neighbors)
        cursor += 1
      }
      guard (3...12).contains(group.count) else { continue }
      group.sort { sources[$0].box.minY < sources[$1].box.minY }
      let values = Array(group.dropFirst())
      if
        let first = group.first,
        sources[first].appearance.fontWeight == .bold,
        values.allSatisfy({ sources[$0].appearance.fontWeight.rawValue < OverlayFontWeight.semibold.rawValue }),
        Set(values.map { sources[$0].text }).count == 1,
        sources[first].text != sources[values[0]].text
      {
        // A visible column heading and repeated values remain a semantic group
        // when native table recognition misses an unruled or scaled grid.
        assign(values, topic: sources[first].text, sources: sources, to: &result)
        continue
      }
      guard Set(group.map { sources[$0].text }).count >= 3 else { continue }
      let bounds = group.reduce(CGRect.null) { $0.union(sources[$1].box) }
      let height = group.map { sources[$0].box.height }.sorted()[group.count / 2]
      let size = group.map { sources[$0].appearance.fontSizeScale }.max() ?? 0
      let caption = sources.indices.filter { index in
        let source = sources[index]
        guard
          !group.contains(index), source.tableCell == nil,
          source.recognitionContextID == sources[seed].recognitionContextID,
          source.language.maximalIdentifier == sources[seed].language.maximalIdentifier,
          !source.needsReview, !source.preservesSource, !source.isProtectedLiteral,
          source.text.count >= 3, source.text.count <= 120, source.text.contains(where: \.isLetter),
          case .horizontal(rows: 1) = source.layout,
          (size > 0 && source.appearance.fontSizeScale >= size * 1.25) || source.appearance.fontWeight == .bold,
          abs(source.box.minY - bounds.minY) <= height * 3
        else { return false }
        let gap = max(0, max(source.box.minX, bounds.minX) - min(source.box.maxX, bounds.maxX))
        return gap <= max(bounds.width * 3, height * 4)
          && (source.box.maxY <= bounds.minY || source.box.maxX <= bounds.minX || source.box.minX >= bounds.maxX)
      }.min {
        abs(sources[$0].box.midX - bounds.midX) + abs(sources[$0].box.minY - bounds.minY)
          < abs(sources[$1].box.midX - bounds.midX) + abs(sources[$1].box.minY - bounds.minY)
      }
      let topic = caption.map { sources[$0].text } ?? group.map { sources[$0].text }.joined(separator: ", ")
      assign(group, topic: topic, sources: sources, to: &result)
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

  private static func isLabel(_ source: OverlayLine.Source) -> Bool {
    guard case .horizontal(rows: 1) = source.layout else { return false }
    return !source.needsReview && !source.preservesSource && !source.isProtectedLiteral
      && source.appearance.confidence >= 0.2 && source.appearance.fontSizeScale > 0
      && (2...40).contains(source.text.count) && source.text.split(whereSeparator: \.isWhitespace).count <= 4
      && source.text.contains(where: \.isLetter)
      && !source.styleRuns.contains(where: { $0.sourceFragment != nil })
      && TranslationLiteralPlan(source.attributedTextForTranslation()) == nil
  }

  private static func aligned(_ a: OverlayLine.Source, _ b: OverlayLine.Source) -> Bool {
    guard a.recognitionContextID == b.recognitionContextID, a.language.maximalIdentifier == b.language.maximalIdentifier else {
      return false
    }
    if let first = a.tableCell, let second = b.tableCell, first.table != second.table { return false }
    let height = max(a.box.height, b.box.height)
    guard
      min(a.box.height, b.box.height) >= height * 0.7,
      abs(a.box.midY - b.box.midY) >= height * 0.8,
      max(a.box.minY, b.box.minY) - min(a.box.maxY, b.box.maxY) <= height * 3,
      min(abs(a.box.minX - b.box.minX), abs(a.box.maxX - b.box.maxX)) * max(0.01, a.imageAspectRatio) <= height * 0.5,
      a.appearance.background.distance(to: b.appearance.background) <= 0.06
    else { return false }
    let sizes = [a.appearance.fontSizeScale, b.appearance.fontSizeScale]
    if sizes.min()! > 0, sizes.max()! / sizes.min()! > 1.25 { return false }
    if let first = a.surface, let second = b.surface {
      let x = first.clippingBox ?? first.box
      let y = second.clippingBox ?? second.box
      let overlap = x.intersection(y)
      guard !overlap.isNull, overlap.width * overlap.height >= min(x.width * x.height, y.width * y.height) * 0.85 else {
        return false
      }
    }
    return true
  }

  private static func assign(_ indices: [Int], topic: String, sources: [OverlayLine.Source], to result: inout [Int: Member]) {
    let group = Self(topic: topic, labels: indices.map { sources[$0].text })
    guard group.attributedRequest != nil else { return }
    for (index, sourceIndex) in indices.enumerated() { result[sourceIndex] = Member(context: group, index: index) }
  }

  private static func link(_ index: Int) -> URL {
    URL(string: "swiftycrow-context://item/\(index)")!
  }
}
