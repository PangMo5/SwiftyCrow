// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Semantic punctuation must remain available to the translator even when
/// Vision gives a numeral and its following comma the same physical box.
enum OCRInlinePunctuation {
  static func separating(after range: NSRange, in line: OCRResult.Line, image: CGImage) -> OCRResult.Line {
    let boundary = NSMaxRange(range)
    guard let carrier = line.styleRuns.last(where: { $0.range.location < boundary && NSMaxRange($0.range) >= boundary })
    else { return line }
    let size = CGSize(width: image.width, height: image.height)
    func sameBox(_ box: CGRect) -> Bool {
      abs(box.minX - carrier.box.minX) * size.width < 0.25 && abs(box.maxX - carrier.box.maxX) * size.width < 0.25
        && abs(box.minY - carrier.box.minY) * size.height < 0.25 && abs(box.maxY - carrier.box.maxY) * size.height < 0.25
    }
    let group = line.styleRuns.filter { sameBox($0.box) }
    let start = group.map(\.range.location).min() ?? boundary
    let end = group.map { NSMaxRange($0.range) }.max() ?? boundary
    guard start < boundary, end > boundary, end <= line.text.utf16.count else { return line }
    let suffix = (line.text as NSString).substring(with: NSRange(location: boundary, length: end - boundary))
    guard suffix.count == 1, suffix.allSatisfy({ ",.;:!?،，。".contains($0) }) else { return line }
    let box = group.reduce(carrier.box) { $0.union($1.inkBox ?? $1.box) }
    let region = CGRect(
      x: box.minX * size.width,
      y: box.minY * size.height,
      width: box.width * size.width,
      height: box.height * size.height
    )
    .insetBy(dx: 0, dy: -1).integral.intersection(CGRect(origin: .zero, size: size))
    guard
      region.width >= 3, region.height >= 3, region.width * region.height <= 100_000,
      let crop = image.cropping(to: region),
      let context = CGContext(
        data: nil,
        width: crop.width,
        height: crop.height,
        bitsPerComponent: 8,
        bytesPerRow: crop.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let bytes = context.data?.assumingMemoryBound(to: UInt8.self)
    else { return line }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    let background = (0..<3).map { channel in
      let values = (0..<crop.width).flatMap { x in [
        Int(bytes[x * 4 + channel]),
        Int(bytes[((crop.height - 1) * crop.width + x) * 4 + channel]),
      ] }.sorted()
      return values[values.count / 2]
    }
    func hasInk(_ x: Int, _ y: Int) -> Bool {
      let index = (y * crop.width + x) * 4
      return (0..<3).contains { abs(Int(bytes[index + $0]) - background[$0]) > 3 }
    }
    let columns = (0..<crop.width).filter { x in (0..<crop.height).contains { hasInk(x, $0) } }
    guard let gap = Array(zip(columns, columns.dropFirst())).last(where: { $1 - $0 > 1 }) else { return line }
    let cut = (gap.0 + gap.1 + 1) / 2
    func ink(in xs: Range<Int>) -> CGRect? {
      var bounds = CGRect.null
      for x in xs { for y in 0..<crop.height where hasInk(x, y) {
        bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
      } }
      return bounds.isNull ? nil : bounds
    }
    guard
      let leftInk = ink(in: 0..<cut), let rightInk = ink(in: cut..<crop.width), rightInk.width <= region.height * 0.65,
      rightInk.maxY >= leftInk.midY
    else { return line }
    let pointSize = line.appearance.fontSizeScale * size.height
    guard pointSize.isFinite, pointSize > 0 else { return line }
    if ",.،，。".contains(suffix) {
      // A trailing digit joined to a comma is not a punctuation component.
      // Both absolute and relative ink heights must describe low punctuation.
      guard rightInk.height <= min(pointSize * 0.55, leftInk.height * 0.6), rightInk.minY >= leftInk.midY else { return line }
    } else if ":;".contains(suffix) {
      let ys = (Int(rightInk.minY)..<Int(rightInk.maxY)).filter { y in
        (cut..<crop.width).contains { hasInk($0, y) }
      }
      var bands = [Int]()
      var previous = -2
      for y in ys {
        if y == previous + 1 { bands[bands.count - 1] += 1 } else { bands.append(1) }
        previous = y
      }
      guard bands.count == 2, CGFloat(bands[0]) <= pointSize * 0.3, CGFloat(bands[1]) <= pointSize * 0.55 else { return line }
    } else { return line }
    func normalized(_ rect: CGRect) -> CGRect {
      CGRect(
        x: (region.minX + rect.minX) / size.width,
        y: (region.minY + rect.minY) / size.height,
        width: rect.width / size.width,
        height: rect.height / size.height
      )
    }
    let left = normalized(CGRect(x: 0, y: 0, width: cut, height: crop.height))
    let right = normalized(CGRect(x: cut, y: 0, width: crop.width - cut, height: crop.height))
    var result = line
    result.styleRuns = line.styleRuns.flatMap { run -> [OverlaySourceStyleRun] in
      guard sameBox(run.box) else { return [run] }
      var pieces = [OverlaySourceStyleRun]()
      for (scope, bounds, inkBox) in [
        (NSRange(location: start, length: boundary - start), left, leftInk),
        (NSRange(location: boundary, length: end - boundary), right, rightInk),
      ] {
        let intersection = NSIntersectionRange(run.range, scope)
        guard intersection.length > 0 else { continue }
        var piece = run
        piece.range = intersection
        piece.box = bounds
        piece.inkBox = normalized(inkBox)
        pieces.append(piece)
      }
      return pieces
    }
    return result
  }
}
