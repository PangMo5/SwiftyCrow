// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText

/// Preserve the captured arrangement of inline arithmetic instead of trusting
/// OCR's flattened exponents. Text selects a candidate; exclusive measured
/// ownership, a common physical row and a flat surface authorize its pixels.
enum OCRInlineSourceFragments {

  // MARK: Internal

  static func candidateRanges(in text: String) -> [NSRange] {
    expressions.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).map(\.range)
  }

  static func requiresResolvedOwnership(_ result: OCRResult) -> Bool {
    result.lines.contains { line in
      !line.isVerticalBlock && !line.preservesSource && !line.needsReview
        && abs(line.rotationRadians) < 0.025 && line.appearance.fontSizeScale > 0
        && hasCompleteRunCoverage(line) && !candidateRanges(in: line.text).isEmpty
    }
  }

  static func resolving(
    _ result: OCRResult,
    image: CGImage,
    resolve: @Sendable (OCRResult, CGImage) async -> OCRResult? = { result, image in
      await SourceRestorationBuilder.resolvingOwnership(to: result, image: image)
    }
  ) async throws -> OCRResult {
    try Task.checkCancellation()
    let restored = await resolve(result, image)
    try Task.checkCancellation()
    guard let restored else { throw CocoaError(.coderInvalidValue) }
    return applying(to: restored, image: image)
  }

  static func applying(to result: OCRResult, image: CGImage) -> OCRResult {
    var result = result
    let size = CGSize(width: image.width, height: image.height)
    for index in result.lines.indices {
      var line = result.lines[index]
      guard
        !line.isVerticalBlock, !line.preservesSource, !line.needsReview,
        abs(line.rotationRadians) < 0.025,
        line.appearance.fontSizeScale > 0, hasCompleteRunCoverage(line)
      else { continue }
      for range in candidateRanges(in: line.text) {
        line = OCRInlinePunctuation.separating(after: range, in: line, image: image)
        let owned = line.styleRuns.filter { NSIntersectionRange($0.range, range).length > 0 }
        guard
          !owned.isEmpty,
          owned.allSatisfy({ NSIntersectionRange($0.range, range) == $0.range && $0.sourceFragment == nil }),
          let first = owned.first,
          owned.allSatisfy({ abs($0.box.midY - first.box.midY) <= min($0.box.height, first.box.height) * 0.4 })
        else { continue }
        var covered = IndexSet()
        for run in owned { covered.insert(integersIn: run.range.location..<NSMaxRange(run.range)) }
        let units = Array(line.text.utf16)
        guard
          (range.location..<NSMaxRange(range)).allSatisfy({ offset in
            covered.contains(offset) || UnicodeScalar(units[offset]).map { CharacterSet.whitespaces.contains($0) } == true
          })
        else { continue }
        let box = owned.reduce(first.box) { bounds, run in
          let ink = run.inkBox.map { $0.insetBy(dx: -1 / size.width, dy: -1 / size.height) } ?? run.box
          return bounds.union(run.box).union(ink)
        }
        let pixels = pixelBox(box, size: size).integral.intersection(CGRect(origin: .zero, size: size))
        guard pixels.width >= 3, pixels.height >= 3, pixels.width * pixels.height <= 100_000 else { continue }
        let neighbors = line.styleRuns.filter { NSIntersectionRange($0.range, range).length == 0 }
        let fontSize = line.appearance.fontSizeScale * size.height
        guard let baseline = baseline(from: neighbors, row: box, text: line.text, fontSize: fontSize, size: size)
        else { continue }
        guard let captured = capture(image: image, bounds: pixels, background: line.appearance.background) else { continue }
        let ink = captured.bounds
        let foreignInk = result.lines.enumerated().filter {
          $0.offset != index && $0.element.recognitionContextID == line.recognitionContextID
        }.flatMap { _, other -> [CGRect] in
          let measured = hasCompleteRunCoverage(other)
            ? other.styleRuns.map { $0.inkBox ?? $0.box }
            : [other.boundingBoxNormalized]
          return measured + other.layoutExclusions
        } + line.layoutExclusions
        guard !foreignInk.contains(where: { pixelBox($0, size: size).intersects(ink) }) else { continue }
        // Padded Vision boxes can contain another row or punctuation owned by
        // a different range. Never carry those pixels along with the literal.
        guard
          !neighbors.contains(where: {
            pixelBox($0.inkBox ?? $0.box, size: size).intersects(ink)
          })
        else { continue }
        guard
          let fragment = OverlayInlineSourceFragment(
            pixels: captured.pixels,
            width: Int(ink.width),
            height: Int(ink.height),
            descent: ink.maxY - baseline,
            referenceFontSize: fontSize
          )
        else { continue }
        let normalized = CGRect(
          x: ink.minX / size.width,
          y: ink.minY / size.height,
          width: ink.width / size.width,
          height: ink.height / size.height
        )
        let run = OverlaySourceStyleRun(
          range: range,
          box: box,
          appearance: line.appearance,
          inkBox: normalized,
          sourceFragment: fragment
        )
        line.styleRuns.removeAll { NSIntersectionRange($0.range, range).length > 0 }
        line.styleRuns.append(run)
        line.styleRuns.sort { $0.range.location < $1.range.location }
      }
      result.lines[index] = line
    }
    return result
  }

  // MARK: Private

  private static let expressions: NSRegularExpression = {
    let atom = #"(?:[0-9]+(?:[.,][0-9]+)?(?:[A-Za-z]|[°⁰¹²³⁴⁵⁶⁷⁸⁹\"']{1,2})?|[A-Za-z])"#
    let arithmetic = #"[-−]?\(?"# + atom + #"\)?(?:\h*[-+−*/^=<>×÷]\h*\(?"# + atom + #"\)?)+"#
    let negativeGroup = #"[-−]\h*\(\h*"# + atom + #"\h*\)"#
    let raisedNumber = #"[0-9]+[°⁰¹²³⁴⁵⁶⁷⁸⁹\"']{1,2}"#
    return try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?:"# + arithmetic + "|" + negativeGroup + "|" + raisedNumber +
      #")(?![\p{L}\p{N}_])"#)
  }()

  private static func hasCompleteRunCoverage(_ line: OCRResult.Line) -> Bool {
    guard !line.text.isEmpty, !line.styleRuns.isEmpty else { return false }
    var covered = IndexSet()
    for run in line.styleRuns {
      guard run.range.length > 0, Range(run.range, in: line.text) != nil else { return false }
      covered.insert(integersIn: run.range.location..<NSMaxRange(run.range))
    }
    return line.text.utf16.enumerated().allSatisfy { index, unit in
      covered.contains(index) || UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } == true
    }
  }

  private static func pixelBox(_ box: CGRect, size: CGSize) -> CGRect {
    CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
  }

  private static func baseline(
    from runs: [OverlaySourceStyleRun],
    row: CGRect,
    text: String,
    fontSize: CGFloat,
    size: CGSize
  ) -> CGFloat? {
    let candidates = runs.compactMap { run -> CGFloat? in
      guard
        run.sourceFragment == nil, let ink = run.inkBox,
        abs(run.box.midY - row.midY) <= min(run.box.height, row.height) * 0.4,
        let range = Range(run.range, in: text),
        text[range].unicodeScalars.count(where: CharacterSet.letters.contains) >= 2,
        text[range].unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) })
      else { return nil }
      let font = NSFont.systemFont(ofSize: fontSize, weight: run.appearance.fontWeight.nsFontWeight)
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(text[range]), attributes: [.font: font]))
      let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
      return ink.maxY * size.height + bounds.minY
    }.sorted()
    guard candidates.count >= 3 else { return nil }
    let median = candidates[candidates.count / 2]
    guard candidates.count(where: { abs($0 - median) <= 1.5 }) >= 3 else { return nil }
    return median
  }

  private static func capture(image: CGImage, bounds: CGRect, background: OverlayColor) -> (bounds: CGRect, pixels: Data)? {
    // OCR can clip a parenthesis or raised glyph at the vertical box edge.
    // Find the nearest clean row on either side in one bounded raster. Do not
    // widen horizontal cuts, which may deliberately separate punctuation.
    let margin = min(8, max(1, ceil(bounds.height * 0.25)))
    let samplingBounds = bounds.insetBy(dx: 0, dy: -margin)
      .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard
      let crop = image.cropping(to: samplingBounds),
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
    else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    let bg = [background.red, background.green, background.blue].map { Int(($0 * 255).rounded()) }
    func difference(x: Int, y: Int) -> Int {
      let offset = (y * crop.width + x) * 4
      return (0..<3).map { abs(Int(bytes[offset + $0]) - bg[$0]) }.max() ?? 0
    }
    func isClear(_ y: Int) -> Bool {
      (0..<crop.width).allSatisfy { difference(x: $0, y: y) <= 12 }
    }
    let originalTop = Int(bounds.minY - samplingBounds.minY)
    let originalBottom = Int(bounds.maxY - samplingBounds.minY) - 1
    guard
      let top = stride(from: originalTop, through: 0, by: -1).first(where: isClear),
      let bottom = (originalBottom..<crop.height).first(where: isClear)
    else { return nil }
    // A rule or another surface crossing the whole crop is not a clipped
    // glyph. Growing past it must not turn background artwork into a formula.
    guard
      !(top...bottom).contains(where: { y in
        (0..<crop.width).allSatisfy { difference(x: $0, y: y) > 12 }
      })
    else { return nil }
    var minX = crop.width
    var minY = crop.height
    var maxX = -1
    var maxY = -1
    for y in top...bottom { for x in 0..<crop.width where difference(x: x, y: y) > 12 {
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
    } }
    guard maxX >= minX, maxY >= minY else { return nil }
    minX = max(0, minX - 1)
    minY = max(0, minY - 1)
    maxX = min(crop.width - 1, maxX + 1)
    maxY = min(crop.height - 1, maxY + 1)
    let width = maxX - minX + 1
    let height = maxY - minY + 1
    var pixels = Data(capacity: width * height * 4)
    for y in minY...maxY { pixels.append(bytes + (y * crop.width + minX) * 4, count: width * 4) }
    return (
      CGRect(
        x: samplingBounds.minX + CGFloat(minX),
        y: samplingBounds.minY + CGFloat(minY),
        width: CGFloat(width),
        height: CGFloat(height)
      ),
      pixels
    )
  }
}
