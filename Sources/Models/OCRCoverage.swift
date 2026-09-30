// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Text detection and document understanding have different contracts. A
/// nonempty document is not proof that every visible text region was recognized.
enum OCRCoverage {
  /// Bound the model's input while retaining at least twelve pixels of glyph
  /// height. Retina scaling must not select a different long-line failure path.
  static func recognitionSize(crop: CGSize, minimumGlyphHeight: CGFloat) -> CGSize {
    let longest = max(crop.width, crop.height)
    guard longest > 0 else { return crop }
    let scale = min(1, max(1600 / longest, 12 / max(1, minimumGlyphHeight)))
    return CGSize(width: max(1, (crop.width * scale).rounded()), height: max(1, (crop.height * scale).rounded()))
  }

  static func uncovered(_ detected: [CGRect], by recognized: [CGRect]) -> [CGRect] {
    detected.filter { box in
      guard box.width > 0, box.height > 0 else { return false }
      let intersections = recognized.map { $0.intersection(box) }.filter { !$0.isNull && !$0.isEmpty }
      // Use union area: duplicate/nested observations must not double-count
      // their coverage, while separate controls can jointly cover a detected row.
      let edges = Array(Set(intersections.flatMap { [$0.minX, $0.maxX] })).sorted()
      var area: CGFloat = 0
      for (left, right) in zip(edges, edges.dropFirst()) {
        let spans = intersections.filter { $0.minX < right && $0.maxX > left }.sorted { $0.minY < $1.minY }
        var end: CGFloat = -.infinity
        var length: CGFloat = 0
        for span in spans {
          length += max(0, span.maxY - max(end, span.minY))
          end = max(end, span.maxY)
        }
        area += (right - left) * length
      }
      return area < box.width * box.height * 0.65
    }
  }

  /// Some native recognizer inputs contain a visible mixed-direction row but
  /// return no observation. Retry only those still-uncovered long rows, split
  /// at measured background gaps. Never cut through ink or reverse a string.
  static func recoveringUncoveredRows(
    _ detected: [CGRect],
    recognized: [OCRResult.Line],
    image: CGImage,
    recognize: @Sendable (CGRect) async throws -> [OCRResult.Line]
  ) async throws -> [OCRResult.Line] {
    let size = CGSize(width: image.width, height: image.height)
    let missing = uncovered(detected, by: recognized.flatMap(evidenceBoxes))
      .filter { $0.width * size.width >= $0.height * size.height * 8 }
    guard !missing.isEmpty else { return [] }
    guard
      let raster = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return [] }
    raster.draw(image, in: CGRect(origin: .zero, size: size))
    guard let data = raster.data else { return [] }
    let pixels = Data(bytes: data, count: image.width * image.height * 4)
    var remainingRequests = 12
    var result = [OCRResult.Line]()
    for box in missing.prefix(4) {
      try Task.checkCancellation()
      let crop = CGRect(
        x: box.minX * size.width,
        y: box.minY * size.height,
        width: box.width * size.width,
        height: box.height * size.height
      ).insetBy(dx: -max(3, min(9, box.height * size.height * 0.4)), dy: -3)
        .integral.intersection(CGRect(origin: .zero, size: size))
      let first = whitespaceSplit(of: crop, pixels: pixels, width: image.width, height: image.height)
      guard first.count == 2 else { continue }
      var pending = first.map { (crop: $0, depth: 1) }
      var recovered = [OCRResult.Line]()
      var incomplete = false
      while !pending.isEmpty {
        try Task.checkCancellation()
        guard remainingRequests > 0 else { incomplete = true
          break
        }
        let item = pending.removeFirst()
        remainingRequests -= 1
        let lines = try await recognize(item.crop)
        let expected = CGRect(
          x: item.crop.minX / size.width,
          y: box.minY,
          width: item.crop.width / size.width,
          height: box.height
        ).intersection(box)
        if
          !lines.isEmpty, lines.allSatisfy({ $0.recognitionConfidence >= 0.6 }),
          coversHorizontalSpan(expected, by: lines.flatMap(evidenceBoxes))
        {
          recovered.append(contentsOf: lines)
          continue
        }
        let children = item.depth < 4
          ? whitespaceSplit(of: item.crop, pixels: pixels, width: image.width, height: image.height)
          : []
        guard children.count == 2 else { incomplete = true
          break
        }
        pending.append(contentsOf: children.map { (crop: $0, depth: item.depth + 1) })
      }
      // A subset is not recovery of the row. Keep its original source intact
      // if any subregion remains unread, instead of painting a partial sentence.
      guard !incomplete, uncovered([box], by: recovered.flatMap(evidenceBoxes)).isEmpty else { continue }
      let script = OverlayTextFlowResolver.scriptEvidence(in: recovered.map(\.text).joined(separator: " ")).dominantScript
      let rightToLeft = script == "Arab" || script == "Hebr"
      let ordered = recovered.sorted { left, right in
        let a = left.boundingBoxNormalized
        let b = right.boundingBoxNormalized
        if abs(a.midY - b.midY) > min(a.height, b.height) * 0.65 { return a.minY < b.minY }
        return rightToLeft ? a.midX > b.midX : a.midX < b.midX
      }
      result.append(contentsOf: OCRResult(lines: ordered).coalescingParagraphFragments().lines)
    }
    return result
  }

  /// A Latin acronym on an Arabic baseline can be shorter than neighboring
  /// diacritics. A leaf owns its horizontal span when its ink is on that row;
  /// it need not occupy the taller script's full rectangle. The whole detected
  /// row still passes the ordinary two-dimensional coverage gate before use.
  static func coversHorizontalSpan(_ expected: CGRect, by evidence: [CGRect]) -> Bool {
    let spans = evidence.compactMap { box -> CGRect? in
      let overlap = min(expected.maxY, box.maxY) - max(expected.minY, box.minY)
      guard overlap >= min(expected.height, box.height) * 0.5 else { return nil }
      return CGRect(x: box.minX, y: expected.minY, width: box.width, height: expected.height)
    }
    return uncovered([expected], by: spans).isEmpty
  }

  static func evidenceBoxes(for line: OCRResult.Line) -> [CGRect] {
    // Word/range geometry is actual recognition evidence. A large paragraph
    // rectangle alone must not claim an unrecognized row inside its bounds.
    let boxes = line.styleRuns.map(\.box).filter { !$0.isEmpty && !$0.isNull }
    guard !boxes.isEmpty else { return [line.boundingBoxNormalized] }
    // Spaces between words are part of an owned physical row; gaps between
    // rows are not. Use row envelopes so ordinary inter-word whitespace does
    // not trigger additional native work, while absent baselines stay visible.
    var rows = [(anchor: CGRect, envelope: CGRect)]()
    for box in boxes.sorted(by: { line.isVerticalBlock ? $0.midX < $1.midX : $0.midY < $1.midY }) {
      if
        let index = rows.firstIndex(where: { row in
          line.isVerticalBlock
            ? abs(row.anchor.midX - box.midX) <= min(row.anchor.width, box.width) * 0.65
            : abs(row.anchor.midY - box.midY) <= min(row.anchor.height, box.height) * 0.65
        })
      {
        rows[index].envelope = rows[index].envelope.union(box)
      } else {
        rows.append((box, box))
      }
    }
    return rows.map(\.envelope)
  }

  static func whitespaceSplit(of crop: CGRect, pixels: Data, width: Int, height: Int) -> [CGRect] {
    let crop = crop.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard crop.width >= crop.height * 1.7, crop.height >= 8 else { return [] }
    let x0 = Int(crop.minX)
    let x1 = Int(crop.maxX)
    let y0 = Int(crop.minY)
    let y1 = Int(crop.maxY)
    return pixels.withUnsafeBytes { buffer in
      let p = buffer.bindMemory(to: UInt8.self)
      guard p.count >= width * height * 4 else { return [] }
      func color(_ x: Int, _ y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return [Int(p[i]), Int(p[i + 1]), Int(p[i + 2])]
      }
      var buckets = [Int: (count: Int, r: Int, g: Int, b: Int)]()
      for y in [y0, y1 - 1] {
        for x in x0..<x1 {
          let c = color(x, y)
          let key = (c[0] >> 4) << 8 | (c[1] >> 4) << 4 | (c[2] >> 4)
          let old = buckets[key] ?? (0, 0, 0, 0)
          buckets[key] = (old.count + 1, old.r + c[0], old.g + c[1], old.b + c[2])
        }
      }
      guard
        let dominant = buckets.values.max(by: { $0.count < $1.count }),
        dominant.count * 2 >= (x1 - x0) * 2
      else { return [] }
      let background = [dominant.r / dominant.count, dominant.g / dominant.count, dominant.b / dominant.count]
      var gaps = [Range<Int>]()
      var start: Int?
      let minimumGap = max(3, Int(ceil((crop.height - 6) * 0.15)))
      for x in x0..<x1 {
        let hasInk = (y0..<y1).contains { y in
          zip(color(x, y), background).contains { abs($0 - $1) > 32 }
        }
        if !hasInk { if start == nil { start = x } }
        else if let from = start {
          if x - from >= minimumGap { gaps.append(from..<x) }
          start = nil
        }
      }
      // Exterior margins do not partition the observed text. Both children
      // must retain a meaningful glyph-width span, with their boundary blank.
      let minimumSpan = max(6, (crop.height - 6) * 0.5)
      let eligible = gaps.filter {
        CGFloat($0.lowerBound) - crop.minX >= minimumSpan
          && crop.maxX - CGFloat($0.upperBound) >= minimumSpan
      }
      guard
        let gap = eligible.min(by: {
          abs(CGFloat($0.lowerBound + $0.upperBound) / 2 - crop.midX)
            < abs(CGFloat($1.lowerBound + $1.upperBound) / 2 - crop.midX)
        })
      else { return [] }
      return [
        CGRect(x: crop.minX, y: crop.minY, width: CGFloat(gap.upperBound) - crop.minX, height: crop.height),
        CGRect(x: CGFloat(gap.lowerBound), y: crop.minY, width: crop.maxX - CGFloat(gap.lowerBound), height: crop.height),
      ]
    }
  }

  static func cropBounds(for regions: [CGRect], imageSize: CGSize) -> CGRect? {
    guard let first = regions.first else { return nil }
    let union = regions.dropFirst().reduce(first) { $0.union($1) }
    return CGRect(
      x: union.minX * imageSize.width,
      y: union.minY * imageSize.height,
      width: union.width * imageSize.width,
      height: union.height * imageSize.height
    )
    .insetBy(dx: -3, dy: -3).integral.intersection(CGRect(origin: .zero, size: imageSize))
  }
}
