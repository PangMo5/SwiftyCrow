// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A Vision observation can contain several physical rows in reversed textual
/// order. Recover rows from range geometry before paragraph analysis.
enum OCRObservationRows {
  static func split(_ lines: [OCRResult.Line]) -> [OCRResult.Line] {
    let rows = lines.flatMap(split)
    let owned = rows.map { row -> CGRect? in
      guard let first = row.styleRuns.first else { return nil }
      return row.styleRuns.dropFirst().reduce(first.box) { $0.union($1.box) }
    }
    return rows.indices.map { index in
      var row = rows[index]
      guard
        !row.isVerticalBlock, abs(row.rotationRadians) < 0.025,
        let ink = owned[index], ink.height < row.boundingBoxNormalized.height * 0.85,
        ink.width >= row.boundingBoxNormalized.width * 0.8,
        rows.indices.contains(where: { other in
          guard
            other != index, let neighbor = owned[other],
            neighbor.midY < ink.minY || neighbor.midY > ink.maxY
          else { return false }
          let overlap = row.boundingBoxNormalized.intersection(neighbor)
          return !overlap.isNull && overlap.width * overlap.height > neighbor.width * neighbor.height * 0.2
        })
      else { return row }
      // Reading order must not use padding that encloses another row's ink.
      row.boundingBoxNormalized = ink
      row.orientedBox = nil
      return row
    }
  }

  static func split(_ line: OCRResult.Line) -> [OCRResult.Line] {
    guard !line.isVerticalBlock, line.text.contains(where: \.isNewline) else { return [line] }
    let text = line.text as NSString
    let matches = try! NSRegularExpression(pattern: #"[^\r\n]+"#).matches(
      in: line.text,
      range: NSRange(location: 0, length: text.length)
    )
    let rows = matches.compactMap { match -> OCRResult.Line? in
      let value = text.substring(with: match.range).trimmingCharacters(in: .whitespaces)
      guard !value.isEmpty else { return nil }
      let range = text.range(of: value, range: match.range)
      let runs = line.styleRuns.filter { NSIntersectionRange($0.range, range).length > 0 }
      guard let first = runs.first else { return nil }
      let box = runs.dropFirst().reduce(first.box) { $0.union($1.box) }
      var row = line
      row.text = value
      row.boundingBoxNormalized = box
      row.orientedBox = nil
      row.rowCount = 1
      row.followingSeparator = nil
      row.continuesToNextLine = NSMaxRange(match.range) < text.length ? true : line.continuesToNextLine
      row.horizontalGlyphScale = runs.map(\.box.height).sorted()[runs.count / 2]
      row.styleRuns = runs.map { run in
        var run = run
        let overlap = NSIntersectionRange(run.range, range)
        run.range = NSRange(location: overlap.location - range.location, length: overlap.length)
        return run
      }
      row.replacementPatches = runs.map { .init(box: $0.box, appearance: $0.appearance) }
      row.spacingAnchors = []
      return row
    }
    guard rows.count == matches.count, rows.count > 1 else { return [line] }
    return rows.sorted { $0.boundingBoxNormalized.midY < $1.boundingBoxNormalized.midY }
  }
}
