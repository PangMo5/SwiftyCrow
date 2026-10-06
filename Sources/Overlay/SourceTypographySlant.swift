// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Synchronization

/// Deskewing italic stems concentrates their ink into vertical columns. Compare
/// that evidence with upright renderings of the same text so diagonal letters
/// alone cannot be mistaken for emphasis. No word or website has a style rule.
enum SourceTypographySlant {

  // MARK: Internal

  static func canMeasure(text: String, width: Int, height: Int) -> Bool {
    (3...80).contains(text.count) && (7...128).contains(height) && (4...2048).contains(width)
      && text.unicodeScalars.allSatisfy { $0.value <= 0x024F }
      && text.contains(where: \.isLetter)
  }

  static func isItalic(text: String, ink: [CGFloat], width: Int, height: Int) -> Bool {
    guard canMeasure(text: text, width: width, height: height), ink.count == width * height else { return false }
    let observed = projection(ink, width: width, height: height)
    guard
      observed.shear >= 0.125, observed.gain >= 0.008,
      hasConsistentStemShift(ink, width: width, height: height)
    else { return false }
    let key = Key(text: text, height: height)
    let neutral: CGFloat
    if let cached = cache.withLock({ $0[key] }) { neutral = cached }
    else {
      // Thresholded capture ink and font outlines can differ by one raster row
      // after resampling. Compare the upright envelope, not one exact height:
      // that quantization must not become semantic emphasis.
      let heights = max(1, height - 1)...height + 1
      let references = heights.flatMap { height in
        fonts.values.flatMap { font in
          [CGFloat(0), 0.5].map { reference(text, font: font, height: height, phase: $0) }
        }
      }
      guard references.allSatisfy({ $0 != nil }) else { return false }
      // Diagonal glyphs can favor either edge after rasterization. Treat both
      // directions as neutral shape evidence rather than assuming one sign.
      neutral = references.compactMap { $0 }.filter { abs($0.shear) >= 0.1 }.map(\.gain).max() ?? 0
      cache.withLock {
        if $0.count >= 512 { $0.removeAll(keepingCapacity: true) }
        $0[key] = neutral
      }
    }
    return observed.gain - neutral >= 0.008 && observed.gain > neutral * 1.5
  }

  // MARK: Private

  private struct Key: Hashable {
    var text: String
    var height: Int
  }

  private struct Projection {
    var shear: CGFloat
    var gain: CGFloat
  }

  private final class Fonts: @unchecked Sendable {
    let values: [CTFont] = ["Arial", "Times New Roman", "Georgia", "Verdana", "Menlo", "Courier"].flatMap { name in
      let font = CTFontCreateWithName(name as CFString, 32, nil)
      return [font, CTFontCreateCopyWithSymbolicTraits(font, 32, nil, .traitBold, .traitBold) ?? font]
    } + [NSFont.systemFont(ofSize: 32) as CTFont, NSFont.boldSystemFont(ofSize: 32) as CTFont]
  }

  private static let cache = Mutex<[Key: CGFloat]>([:])
  private static let fonts = Fonts()

  private static func projection(_ ink: [CGFloat], width: Int, height: Int) -> Projection {
    let rows = height / 5..<height * 4 / 5
    var points = [(Int, Int, CGFloat)]()
    var energies = [(y: Int, square: CGFloat, adjacent: CGFloat)]()
    for y in rows {
      var square: CGFloat = 0
      var adjacent: CGFloat = 0
      var previous: CGFloat = 0
      for x in 0..<width {
        let value = ink[y * width + x]
        let strength: CGFloat = value >= 0.15 ? value : 0
        if strength > 0 { points.append((x, y, strength)) }
        square += strength * strength
        adjacent += strength * previous
        previous = strength
      }
      energies.append((y, square, adjacent))
    }
    guard points.count >= 20 else { return Projection(shear: 0, gain: 0) }
    var best: CGFloat = 0
    var zero: CGFloat = 0
    var shear: CGFloat = 0
    for step in -12...16 {
      let candidate = CGFloat(step) * 0.025
      var columns = [CGFloat](repeating: 0, count: width + height)
      for (x, y, ink) in points {
        let position = CGFloat(x) + candidate * CGFloat(y - height / 2) + CGFloat(height / 2)
        let lower = Int(floor(position))
        let fraction = position - CGFloat(lower)
        guard lower >= 0, lower + 1 < columns.count else { continue }
        columns[lower] += ink * (1 - fraction)
        columns[lower + 1] += ink * fraction
      }
      // A fractional shift spreads one pixel into two columns. Normalize by
      // each shifted row's energy, otherwise integer-aligned upright stems win
      // simply because the other candidates undergo interpolation.
      let rowEnergy = energies.reduce(CGFloat.zero) { total, row in
        let phase = candidate * CGFloat(row.y - height / 2)
        let fraction = phase - floor(phase)
        return total + ((1 - fraction) * (1 - fraction) + fraction * fraction) * row.square
          + 2 * fraction * (1 - fraction) * row.adjacent
      }
      let score = columns.reduce(0) { $0 + $1 * $1 } / max(0.001, rowEnergy)
      if step == 0 { zero = score }
      if score > best {
        best = score
        shear = candidate
      }
    }
    return Projection(shear: shear, gain: zero > 0 ? (best - zero) / zero : 0)
  }

  /// Slant must move several stems in the same direction. A word's diagonal
  /// curves can improve projection energy without changing its upright stems.
  private static func hasConsistentStemShift(_ ink: [CGFloat], width: Int, height: Int) -> Bool {
    func centers(_ rows: Range<Int>) -> [CGFloat] {
      let columns = (0..<width).map { x in rows.reduce(CGFloat.zero) { $0 + ink[$1 * width + x] } }
      let threshold = (columns.max() ?? 0) * 0.65
      var groups = [[Int]]()
      for x in columns.indices where columns[x] > threshold {
        if groups.last?.last == x - 1 { groups[groups.count - 1].append(x) } else { groups.append([x]) }
      }
      return groups.map { group in
        let weight = group.reduce(CGFloat.zero) { $0 + columns[$1] }
        return group.reduce(CGFloat.zero) { $0 + CGFloat($1) * columns[$1] } / max(0.001, weight)
      }
    }
    let top = centers(height / 5..<height / 2)
    let bottom = centers(height / 2..<height * 4 / 5)
    let shifts = top.compactMap { x -> CGFloat? in
      guard let match = bottom.min(by: { abs($0 - x) < abs($1 - x) }), abs(match - x) <= max(2, CGFloat(height) * 0.35)
      else { return nil }
      return x - match
    }.sorted()
    guard shifts.count >= 2 else { return false }
    let delta = CGFloat(height) * 0.3
    return shifts[shifts.count / 2] > max(0.25, delta * 0.08)
      && shifts.count(where: { $0 > 0.2 }) * 2 >= shifts.count
  }

  private static func reference(_ text: String, font: CTFont, height: Int, phase: CGFloat) -> Projection? {
    let reference = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let referenceBounds = CTLineGetBoundsWithOptions(reference, [.useGlyphPathBounds])
    guard referenceBounds.width > 0, referenceBounds.height > 0 else { return nil }
    // Render at the observed point size. Scaling a 32-point outline erases
    // small-font hinting/optical metrics and can turn an upright link into slant.
    let pointSize = CTFontGetSize(font) * CGFloat(height) / referenceBounds.height
    let observedFont = CTFontCreateCopyWithAttributes(font, pointSize, nil, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: observedFont]))
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    let width = Int(ceil(bounds.width + 1))
    guard
      width > 0, width <= 4096, let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.textPosition = CGPoint(x: -bounds.minX + phase, y: -bounds.minY + phase)
    CTLineDraw(line, context)
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    // Bitmap rows and source-raster rows share the same top-to-bottom order.
    return projection((0..<width * height).map { CGFloat(pixels[$0 * 4 + 3]) / 255 }, width: width, height: height)
  }
}
