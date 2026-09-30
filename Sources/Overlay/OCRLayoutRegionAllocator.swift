// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Source glyph masks and target layout space are different things. After
/// paragraph composition, a horizontal text unit may use verified whitespace,
/// bounded by neighboring text and by any non-text artwork in the pixels.
/// Allocation never changes recognition, grouping, or the source erasure mask.
enum OCRLayoutRegionAllocator {

  // MARK: Internal

  static func allocating(_ result: OCRResult, width: Int, height: Int, sample: (Int, Int) -> OverlayColor?) -> OCRResult {
    var output = result
    for index in result.lines.indices {
      let line = result.lines[index]
      let box = line.boundingBoxNormalized
      guard
        !line.isVerticalBlock, abs(line.rotationRadians) < 0.025,
        !line.preservesSource,!OCRTextSemantics.isCode(line.text),!OCRTextSemantics.isIdentifier(line.text)
      else { continue }
      var left: CGFloat = 0
      var right: CGFloat = 1
      for otherIndex in result.lines.indices where otherIndex != index {
        let peer = result.lines[otherIndex].boundingBoxNormalized
        let overlap = min(box.maxY, peer.maxY) - max(box.minY, peer.minY)
        guard overlap > min(box.height, peer.height) * 0.5 else { continue }
        if peer.maxX <= box.minX { left = max(left, (peer.maxX + box.minX) / 2) }
        if peer.minX >= box.maxX { right = min(right, (box.maxX + peer.minX) / 2) }
      }
      let y0 = max(0, Int(box.minY * CGFloat(height)))
      let y1 = min(height, Int(ceil(box.maxY * CGFloat(height))))
      guard y1 > y0 else { continue }
      func clear(_ x: Int) -> Bool {
        guard (0..<width).contains(x) else { return false }
        return (y0..<y1).allSatisfy { y in
          guard let color = sample(x, y) else { return false }
          return max(
            abs(color.red - line.appearance.background.red),
            abs(color.green - line.appearance.background.green),
            abs(color.blue - line.appearance.background.blue)
          ) < 0.025
        }
      }
      var leftEdge = max(0, Int(floor(box.minX * CGFloat(width))))
      var rightEdge = min(width, Int(ceil(box.maxX * CGFloat(width))))
      while leftEdge > Int(ceil(left * CGFloat(width))), clear(leftEdge - 1) { leftEdge -= 1 }
      while rightEdge < Int(floor(right * CGFloat(width))), clear(rightEdge) { rightEdge += 1 }
      var bottomEdge = y1
      let prose = line
        .rowCount > 1 ||
        (line.text.count >= 12 && line.text.last?.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains) == true)
      if prose {
        var bottom: CGFloat = 1
        for otherIndex in result.lines.indices where otherIndex != index {
          let peer = result.lines[otherIndex].boundingBoxNormalized
          guard
            peer.minY >= box.maxY, peer.maxX > CGFloat(leftEdge) / CGFloat(width),
            peer.minX < CGFloat(rightEdge) / CGFloat(width)
          else { continue }
          bottom = min(bottom, (box.maxY + peer.minY) / 2)
        }
        while bottomEdge < Int(floor(bottom * CGFloat(height))) {
          let empty = (leftEdge..<rightEdge).allSatisfy { x in
            guard let color = sample(x, bottomEdge) else { return false }
            return max(
              abs(color.red - line.appearance.background.red),
              abs(color.green - line.appearance.background.green),
              abs(color.blue - line.appearance.background.blue)
            ) < 0.025
          }
          guard empty else { break }
          bottomEdge += 1
        }
      }
      output.lines[index].layoutBounds = CGRect(
        x: CGFloat(leftEdge) / CGFloat(width),
        y: box.minY,
        width: CGFloat(max(0, rightEdge - leftEdge)) / CGFloat(width),
        height: max(box.height, CGFloat(bottomEdge) / CGFloat(height) - box.minY)
      )
      output.lines[index].textFlowRegions = flowRegions(
        for: line,
        within: output.lines[index].layoutBounds!,
        width: width,
        height: height,
        sample: sample
      )
    }
    return output
  }

  // MARK: Private

  /// Preserve the empty space around each physical source row. A paragraph's
  /// union box can cross a floating figure/table even though none of its rows
  /// does. Only scan outside owned glyphs, stopping at the first different
  /// surface, border, graphic or neighboring text.
  private static func flowRegions(
    for line: OCRResult.Line,
    within available: CGRect,
    width: Int,
    height: Int,
    sample: (Int, Int) -> OverlayColor?
  ) -> [CGRect] {
    guard line.rowCount >= 3 else { return [] }
    let boxes = line.styleRuns.map { $0.inkBox ?? $0.box }.filter { !$0.isEmpty && !$0.isNull }
    var rows = [CGRect]()
    for box in boxes.sorted(by: { $0.midY < $1.midY }) {
      if
        let index = rows.lastIndex(where: { row in
          min(row.maxY, box.maxY) - max(row.minY, box.minY) >= min(row.height, box.height) * 0.5
        }) { rows[index] = rows[index].union(box) }
      else { rows.append(box) }
    }
    guard rows.count >= 3 else { return [] }
    let regions = rows.indices.map { index -> CGRect in
      let row = rows[index]
      let top = index == 0 ? available.minY : (rows[index - 1].midY + row.midY) / 2
      let bottom = index == rows.count - 1 ? available.maxY : (row.midY + rows[index + 1].midY) / 2
      let y0 = max(0, Int(floor(top * CGFloat(height))))
      let y1 = min(height, Int(ceil(bottom * CGFloat(height))))
      // Ink bounds exclude faint antialiasing. The full source range still
      // owns those pixels; they are erased with the row, not an obstacle that
      // should reproduce the ragged source line endings in the translation.
      let owned = line.styleRuns.map { $0.box.insetBy(dx: -1 / CGFloat(width), dy: -1 / CGFloat(height)) }
        .filter { $0.maxY >= top && $0.minY <= bottom }
      func clear(_ x: Int) -> Bool {
        guard (0..<width).contains(x), y1 > y0 else { return false }
        return (y0..<y1).allSatisfy { y in
          let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(width), y: (CGFloat(y) + 0.5) / CGFloat(height))
          if owned.contains(where: { $0.contains(point) }) { return true }
          guard let color = sample(x, y) else { return false }
          let background = line.appearance.background
          return max(abs(color.red - background.red), abs(color.green - background.green), abs(color.blue - background.blue)) <
            0.025
        }
      }
      var left = max(0, Int(floor(row.minX * CGFloat(width))))
      var right = min(width, Int(ceil(row.maxX * CGFloat(width))))
      while left > Int(ceil(available.minX * CGFloat(width))), clear(left - 1) { left -= 1 }
      while right < Int(floor(available.maxX * CGFloat(width))), clear(right) { right += 1 }
      return CGRect(
        x: CGFloat(left) / CGFloat(width),
        y: top,
        width: CGFloat(right - left) / CGFloat(width),
        height: bottom - top
      )
    }
    let scale = line.horizontalGlyphScale > 0
      ? line.horizontalGlyphScale
      : line.boundingBoxNormalized.height / CGFloat(rows.count)
    let varyingEdge = max(
      (regions.map(\.minX).max()! - regions.map(\.minX).min()!),
      (regions.map(\.maxX).max()! - regions.map(\.maxX).min()!)
    ) * line.imageAspectRatio
    return varyingEdge > scale * 1.5 ? regions : []
  }
}
