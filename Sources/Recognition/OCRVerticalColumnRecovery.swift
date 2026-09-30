// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A reread may split a physical column at a printed blank gap. Its longest
/// observation is not a replacement for the complete source column.
enum OCRVerticalColumnRecovery {
  static func fragments(for source: OCRResult.Line, candidates: [OCRResult.Line]) -> [OCRResult.Line] {
    guard
      source.isVerticalBlock, source.text.count > 3, source.recognitionConfidence < 0.45,
      source.verticalCharScale > 0, source.imageAspectRatio > 0
    else { return [] }
    let box = source.boundingBoxNormalized
    let glyphX = source.verticalCharScale
    let glyphY = glyphX * source.imageAspectRatio
    let center = box.minX + min(box.width, glyphX) / 2
    let rows = candidates.filter { line in
      let b = line.boundingBoxNormalized
      let overlap = box.intersection(b)
      return line.isVerticalBlock && line.recognitionConfidence >= 0.25
        && b.width >= glyphX * 0.6 && abs(b.midX - center) <= glyphX * 0.35
        && !overlap.isNull && b.width * b.height > 0
        && overlap.width * overlap.height >= b.width * b.height * 0.55
    }.sorted { $0.boundingBoxNormalized.minY < $1.boundingBoxNormalized.minY }
    guard (2...4).contains(rows.count), rows.contains(where: { $0.recognitionConfidence >= 0.45 }) else { return [] }
    for (a, b) in zip(rows, rows.dropFirst()) {
      let gap = b.boundingBoxNormalized.minY - a.boundingBoxNormalized.maxY
      guard gap >= -glyphY * 0.1, gap <= glyphY * 0.85 else { return [] }
    }
    guard
      let first = rows.first, let last = rows.last,
      first.boundingBoxNormalized.minY <= box.minY + glyphY * 0.35,
      last.boundingBoxNormalized.maxY >= box.maxY - glyphY * 0.35
    else { return [] }
    return rows
  }

  /// Weak fragments need matching text from a separate local read. Confidence
  /// remains the observed minimum; agreement is not an invented probability.
  static func confirmedColumn(
    _ fragments: [OCRResult.Line],
    confirm: (OCRResult.Line) async throws -> OCRResult.Line?
  ) async throws -> OCRResult.Line? {
    guard (2...4).contains(fragments.count) else { return nil }
    var rows = [OCRResult.Line]()
    for fragment in fragments {
      try Task.checkCancellation()
      if fragment.recognitionConfidence >= 0.45 { rows.append(fragment)
        continue
      }
      guard
        let fresh = try await confirm(fragment), fresh.text == fragment.text,
        fresh.recognitionConfidence >= 0.25
      else { return nil }
      let a = fragment.boundingBoxNormalized
      let b = fresh.boundingBoxNormalized
      let overlap = a.intersection(b)
      guard
        !overlap.isNull, min(a.width * a.height, b.width * b.height) > 0,
        overlap.width * overlap.height >= min(a.width * a.height, b.width * b.height) * 0.65
      else { return nil }
      rows.append(fresh)
    }
    guard var result = rows.first else { return nil }
    result.text = ""
    result.styleRuns = []
    result.spacingAnchors = []
    result.replacementPatches = []
    for row in rows {
      let offset = result.text.utf16.count
      result.text += row.text
      result.boundingBoxNormalized = result.boundingBoxNormalized.union(row.boundingBoxNormalized)
      result.styleRuns += row.styleRuns.map { run in
        var run = run
        run.range.location += offset
        return run
      }
      result.spacingAnchors += row.spacingAnchors.map { anchor in
        var anchor = anchor
        anchor.range.location += offset
        return anchor
      }
      result.replacementPatches += row.replacementPatches
    }
    result.recognitionConfidence = rows.map(\.recognitionConfidence).min() ?? 0
    result.recognitionLanguages = Set(rows.flatMap(\.recognitionLanguages)).sorted()
    result.orientedBox = nil
    result.rowCount = 1
    result.isVerticalBlock = true
    return result
  }
}
