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
        && hasCompleteRunCoverage(line) &&
        (line.styleRuns.contains { $0.sourceFragment != nil } || !candidateRanges(in: line.text).isEmpty)
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

  static func capturingAnnotations(_ result: OCRResult, image: CGImage) -> OCRResult {
    let size = CGSize(width: image.width, height: image.height)
    return .init(lines: result.lines.map { original in
      var line = original
      for annotation in OCRVisualStructure.inlineAnnotations(in: original) where !annotation.isSeparator {
        let neighbors = original.styleRuns.filter {
          NSIntersectionRange($0.range, annotation.range).length == 0
            && Range($0.range, in: original.text).map { original.text[$0].contains(where: \.isLetter) } == true
            && abs(($0.inkBox ?? $0.box).midY - annotation.inkBox.midY) <= ($0.inkBox ?? $0.box).height
        }
        let fontSize = original.appearance.fontSizeScale * size.height
        guard fontSize > 0, !neighbors.isEmpty else { continue }
        let baselines = neighbors.compactMap { run -> CGFloat? in
          guard let ink = run.inkBox, let range = Range(run.range, in: original.text) else { return nil }
          let reference = CTLineCreateWithAttributedString(NSAttributedString(string: String(original.text[range]), attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: run.appearance.fontWeight.nsFontWeight)
          ]))
          return ink.maxY * size.height + CTLineGetBoundsWithOptions(reference, [.useGlyphPathBounds]).minY
        }.sorted()
        guard !baselines.isEmpty else { continue }
        let baseline = baselines[baselines.count / 2]
        let bounds = pixelBox(annotation.inkBox, size: size).insetBy(dx: -1, dy: -1).integral
          .intersection(CGRect(origin: .zero, size: size))
        guard let fragment = annotationFragment(in: bounds, image: image, baseline: baseline, fontSize: fontSize)
        else { continue }
        line.styleRuns.removeAll { NSIntersectionRange($0.range, annotation.range).length > 0 }
        line.styleRuns.append(.init(
          range: annotation.range,
          box: annotation.inkBox,
          appearance: annotation.runs[0].appearance,
          inkBox: CGRect(
            x: bounds.minX / size.width,
            y: bounds.minY / size.height,
            width: bounds.width / size.width,
            height: bounds.height / size.height
          ),
          sourceFragment: fragment
        ))
        line.styleRuns.sort { $0.range.location < $1.range.location }
      }
      return line
    })
  }

  /// In mixed prose a ruby-annotated term is a quoted source spelling, not a
  /// separate sentence to translate. Carry its base and reading as one inline
  /// object; a translated Japanese paragraph still absorbs its ruby normally.
  static func capturingRubyAnnotations(_ result: OCRResult, image: CGImage) -> OCRResult {
    let size = CGSize(width: image.width, height: image.height)
    var lines = result.lines
    for ruby in result.lines.filter(OCRResult.isLikelyRuby) {
      for index in lines.indices {
        let base = lines[index]
        guard
          !base.isVerticalBlock, base.text.unicodeScalars.count(where: { (0x0041...0x005A).contains($0.value)
              || (0x0061...0x007A).contains($0.value)
          }) >= 8,
          let word = OCRResult.rubyBaseWord(in: base, for: ruby),
          let range = Range(word.range, in: base.text),
          (1...4).contains(base.text[range].count), base.text[range].contains(where: \.isLetter),
          let run = base.styleRuns.first(where: { NSIntersectionRange($0.range, word.range).length > 0 }),
          run.sourceFragment == nil
        else { continue }
        let fontSize = max(run.appearance.fontSizeScale, base.appearance.fontSizeScale) * size.height
        guard fontSize > 0 else { continue }
        let reference = CTLineCreateWithAttributedString(NSAttributedString(string: String(base.text[range]), attributes: [
          .font: NSFont.systemFont(ofSize: fontSize, weight: run.appearance.fontWeight.nsFontWeight)
        ]))
        let ink = run.inkBox ?? word.box
        let baseline = ink.maxY * size.height + CTLineGetBoundsWithOptions(reference, [.useGlyphPathBounds]).minY
        let bounds = pixelBox(ink.union(ruby.boundingBoxNormalized), size: size).insetBy(dx: -1, dy: -1).integral
          .intersection(CGRect(origin: .zero, size: size))
        guard let fragment = annotationFragment(in: bounds, image: image, baseline: baseline, fontSize: fontSize)
        else { continue }
        lines[index].styleRuns.removeAll { NSIntersectionRange($0.range, word.range).length > 0 }
        lines[index].styleRuns.append(.init(
          range: word.range,
          box: word.box,
          appearance: run.appearance,
          inkBox: CGRect(
            x: bounds.minX / size.width,
            y: bounds.minY / size.height,
            width: bounds.width / size.width,
            height: bounds.height / size.height
          ),
          sourceFragment: fragment
        ))
        lines[index].styleRuns.sort { $0.range.location < $1.range.location }
        break
      }
    }
    return .init(lines: lines)
  }

  /// A measured code fill owns exact source spelling even when OCR inserts a
  /// space inside a path. Keep the token's pixels and move only that inline
  /// owner with the surrounding translation; never guess a repaired filename.
  static func capturingCodeLiterals(_ result: OCRResult, image: CGImage) -> OCRResult {
    let size = CGSize(width: image.width, height: image.height)
    return .init(lines: result.lines.map { original in
      guard !original.isVerticalBlock, !original.preservesSource, abs(original.rotationRadians) < 0.025 else { return original }
      var groups = [[OverlaySourceStyleRun]]()
      for run in original.styleRuns.sorted(by: { $0.range.location < $1.range.location }) {
        guard run.sourceFragment == nil, run.appearance.background.distance(to: original.appearance.background) >= 0.06 else {
          groups.append([])
          continue
        }
        if
          let last = groups.last?.last,
          last.appearance.background.distance(to: run.appearance.background) <= 0.035,
          abs(last.box.midY - run.box.midY) <= min(last.box.height, run.box.height) * 0.4,
          run.range.location - NSMaxRange(last.range) <= 2
        {
          groups[groups.count - 1].append(run)
        } else { groups.append([run]) }
      }
      var line = original
      let source = original.text as NSString
      for group in groups {
        guard let first = group.first, let last = group.last else { continue }
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        guard NSMaxRange(range) <= source.length else { continue }
        let value = source.substring(with: range)
        let compact = String(value.filter { !$0.isWhitespace })
        guard
          value.count <= 80, !value.contains(where: \.isNewline),
          OCRVisualStructure.isPath(compact) || OCRTextSemantics.isFileName(compact) || OCRTextSemantics.isCode(value)
        else { continue }
        let box = group.reduce(first.box) { $0.union($1.box).union($1.inkBox ?? $1.box) }
        let neighbors = original.styleRuns.filter { NSIntersectionRange($0.range, range).length == 0 }
        let fontSize = original.appearance.fontSizeScale * size.height
        guard
          fontSize > 0,
          let baseline = baseline(from: neighbors, row: box, text: original.text, fontSize: fontSize, size: size)
        else { continue }
        let bounds = pixelBox(box, size: size).insetBy(dx: -1, dy: -1).integral.intersection(CGRect(origin: .zero, size: size))
        guard
          !neighbors.contains(where: { pixelBox($0.inkBox ?? $0.box, size: size).intersects(bounds) }),
          let fragment = annotationFragment(in: bounds, image: image, baseline: baseline, fontSize: fontSize)
        else { continue }
        line.styleRuns.removeAll { NSIntersectionRange($0.range, range).length > 0 }
        line.styleRuns.append(.init(
          range: range,
          box: box,
          appearance: first.appearance,
          inkBox: CGRect(
            x: bounds.minX / size.width,
            y: bounds.minY / size.height,
            width: bounds.width / size.width,
            height: bounds.height / size.height
          ),
          sourceFragment: fragment
        ))
        line.styleRuns.sort { $0.range.location < $1.range.location }
      }
      return line
    })
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

  private static func annotationFragment(
    in bounds: CGRect,
    image: CGImage,
    baseline: CGFloat,
    fontSize: CGFloat
  ) -> OverlayInlineSourceFragment? {
    guard
      bounds.width > 0, bounds.height > 0, bounds.width * bounds.height <= 100_000,
      let crop = image.cropping(to: bounds),
      let context = CGContext(
        data: nil,
        width: crop.width,
        height: crop.height,
        bitsPerComponent: 8,
        bytesPerRow: crop.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ), let bytes = context.data
    else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    return OverlayInlineSourceFragment(
      pixels: Data(bytes: bytes, count: crop.width * crop.height * 4),
      width: crop.width,
      height: crop.height,
      descent: bounds.maxY - baseline,
      referenceFontSize: fontSize,
      kind: .annotation
    )
  }

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
