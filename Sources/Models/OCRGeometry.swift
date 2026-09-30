// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - OCRGeometry

enum OCRGeometry {
  enum AlignmentEvidence: Equatable, Sendable {
    case unavailable
    case ambiguous
    case aligned(OverlayTextAlignment)

    var alignment: OverlayTextAlignment? {
      guard case .aligned(let alignment) = self else { return nil }
      return alignment
    }
  }

  /// Image-analysis budgets follow physical glyph size, so empty canvas does
  /// not consume the samples needed to distinguish text and ink boundaries.
  /// A lower quartile resists isolated tiny recognition noise; allocation is bounded.
  static func analysisRasterLongestSide(for lines: [OCRResult.Line], imageSize: CGSize) -> Int {
    guard imageSize.width > 0, imageSize.height > 0 else { return 1024 }
    let scales = lines.compactMap { line -> CGFloat? in
      let scale = line.isVerticalBlock && line.verticalCharScale > 0
        ? line.verticalCharScale * imageSize.width / imageSize.height
        : (line.horizontalGlyphScale > 0
          ? line.horizontalGlyphScale
          : line.boundingBoxNormalized.height / CGFloat(max(1, line.rowCount)))
      return scale.isFinite && scale > 0 ? scale : nil
    }.sorted()
    guard !scales.isEmpty else { return 1024 }
    let requiredHeight = 12 / scales[scales.count / 4]
    let requiredSide = requiredHeight * max(imageSize.width, imageSize.height) / imageSize.height
    return Int(min(2048, max(1024, ceil(requiredSide / 256) * 256)))
  }

  /// Alignment comes from complete physical rows, not individual inline spans
  /// or the paragraph's location on the screen. A short final row is evidence.
  static func horizontalAlignmentEvidence(in line: OCRResult.Line) -> AlignmentEvidence {
    guard !line.isVerticalBlock, line.rowCount > 1, abs(line.rotationRadians) <= 0.025 else { return .unavailable }
    let rowHeight = max(line.horizontalGlyphScale, line.boundingBoxNormalized.height / CGFloat(line.rowCount))
    let boxes = line.styleRuns.map(\.box).filter {
      !$0.isNull && !$0.isEmpty && $0.height <= rowHeight * 1.65
    }.sorted { $0.midY < $1.midY }
    var rows = [CGRect]()
    for box in boxes {
      if
        let index = rows.lastIndex(where: { row in
          min(row.maxY, box.maxY) - max(row.minY, box.minY) >= min(row.height, box.height) * 0.55
        }) { rows[index] = rows[index].union(box) }
      else { rows.append(box) }
    }
    return horizontalAlignmentEvidence(forRows: rows, imageAspectRatio: line.imageAspectRatio)
  }

  static func horizontalAlignment(forRows rows: [CGRect], imageAspectRatio: CGFloat) -> OverlayTextAlignment? {
    horizontalAlignmentEvidence(forRows: rows, imageAspectRatio: imageAspectRatio).alignment
  }

  static func horizontalAlignmentEvidence(forRows rows: [CGRect], imageAspectRatio: CGFloat) -> AlignmentEvidence {
    let rows = rows.filter { !$0.isNull && !$0.isEmpty }
    guard rows.count >= 2, imageAspectRatio.isFinite, imageAspectRatio > 0 else { return .unavailable }
    func deviation(_ values: [CGFloat]) -> CGFloat {
      let sorted = values.sorted()
      let median = sorted[sorted.count / 2]
      return values.reduce(0) { $0 + abs($1 - median) } / CGFloat(values.count)
    }
    let candidates: [(alignment: OverlayTextAlignment, error: CGFloat)] = [
      (.leading, deviation(rows.map(\.minX))),
      (.center, deviation(rows.map(\.midX))),
      (.trailing, deviation(rows.map(\.maxX))),
    ].sorted { $0.error < $1.error }
    let rowHeight = rows.map(\.height).sorted()[rows.count / 2]
    // Nearly equal-length rows do not distinguish a centered paragraph from
    // a reading-edge paragraph. Subpixel crop/raster changes must not turn
    // that ambiguous evidence into a new alignment.
    let widths = rows.map(\.width)
    guard (widths.max()! - widths.min()!) * imageAspectRatio > rowHeight else { return .ambiguous }
    // A whole-canvas minimum grows in pixels when empty margins are added.
    // Keep every tolerance in the same physical glyph-relative coordinate system.
    let tolerance = rowHeight * 0.4 / imageAspectRatio
    let best = candidates[0]
    guard best.error <= tolerance, candidates[1].error - best.error > tolerance * 0.15 else { return .ambiguous }
    return .aligned(best.alignment)
  }

  static func verticalCharacterScale(text: String, bounds: CGRect, imageSize: CGSize) -> CGFloat {
    let letters = text.unicodeScalars.count(where: CharacterSet.alphanumerics.contains)
    guard letters >= 2, imageSize.width > 0 else { return bounds.width }
    // A noisy column box may include ruby or nearby artwork. The height per
    // recognized glyph is an independent upper bound on its character size.
    return min(bounds.width, bounds.height * imageSize.height / CGFloat(letters) / imageSize.width)
  }

  /// Pairwise layout comparisons must share a coordinate system. Rotating each
  /// observation by its own noisy angle moves distant short rows disproportionately.
  static func alignedPair(_ lhs: OCRResult.Line, _ rhs: OCRResult.Line) -> (CGRect, CGRect) {
    let leftWeight = max(0.001, lhs.boundingBoxNormalized.width)
    let rightWeight = max(0.001, rhs.boundingBoxNormalized.width)
    let angle = (lhs.rotationRadians * leftWeight + rhs.rotationRadians * rightWeight) / (leftWeight + rightWeight)
    let aspect = max(0.01, lhs.imageAspectRatio)
    return (
      alignedBox(lhs.orientedBox ?? lhs.boundingBoxNormalized, angle: angle, aspect: aspect).standardized,
      alignedBox(rhs.orientedBox ?? rhs.boundingBoxNormalized, angle: angle, aspect: aspect).standardized
    )
  }

  static func isVertical(
    text: String,
    topLeft: CGPoint,
    topRight: CGPoint,
    imageSize: CGSize,
    declaredVertical: Bool,
    bounds: CGRect? = nil
  ) -> Bool {
    if declaredVertical { return true }
    let dx = abs(topRight.x - topLeft.x) * imageSize.width
    let dy = abs(topRight.y - topLeft.y) * imageSize.height
    let count = OverlayTextFlowResolver.scriptEvidence(in: text).verticalCharacterCount
    if dy > dx * 2, count >= 2 { return true }
    // Short upright CJK columns can have horizontal corner vectors and missing
    // direction metadata. Their physical extent still contains a stack of
    // square glyphs; a wrapped multi-column paragraph cannot satisfy this ratio.
    guard let bounds, count >= 2, !text.contains(where: \.isNewline) else { return false }
    let width = bounds.width * imageSize.width
    let height = bounds.height * imageSize.height
    return width > 0 && height / width >= max(1.5, CGFloat(count) * 0.5)
  }

  static func alignedBox(_ box: CGRect, angle: CGFloat, aspect: CGFloat) -> CGRect {
    let x = box.midX * aspect
    let y = box.midY
    return CGRect(
      x: (x * cos(angle) + y * sin(angle)) / aspect - box.width / 2,
      y: -x * sin(angle) + y * cos(angle) - box.height / 2,
      width: box.width,
      height: box.height
    )
  }

  static func combinedFrame(_ lines: [OCRResult.Line], angle: CGFloat) -> CGRect {
    let aspect = lines.first?.imageAspectRatio ?? 1
    let projected = lines.map { alignedBox($0.orientedBox ?? $0.boundingBoxNormalized, angle: angle, aspect: aspect) }
    let union = projected.dropFirst().reduce(projected[0]) { $0.union($1) }
    let x = union.midX * aspect
    let y = union.midY
    return CGRect(
      x: (x * cos(angle) - y * sin(angle)) / aspect - union.width / 2,
      y: x * sin(angle) + y * cos(angle) - union.height / 2,
      width: union.width,
      height: union.height
    )
  }
}

extension OCRResult.Line {
  var alignedBox: CGRect {
    guard abs(rotationRadians) > 0.025 else { return orientedBox ?? boundingBoxNormalized }
    return OCRGeometry.alignedBox(orientedBox ?? boundingBoxNormalized, angle: rotationRadians, aspect: imageAspectRatio)
  }
}
