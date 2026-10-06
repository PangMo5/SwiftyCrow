// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

// MARK: - JapaneseRubyOCRCorrector

/// Re-reads the base-glyph portion of large horizontal Japanese rows in one
/// contact sheet. `RecognizeDocumentsRequest` is excellent at page structure,
/// but dense furigana can be fused with the base characters. A single accurate
/// `RecognizeTextRequest` over the lower part of those rows preserves the page
/// geometry while giving Apple's Japanese recognizer a clean glyph image.
enum JapaneseRubyOCRCorrector {

  // MARK: Internal

  static func verticalCorrectionCrop(for line: OCRResult.Line, among lines: [OCRResult.Line], imageSize: CGSize) -> CGRect {
    let b = line.boundingBoxNormalized
    let nextColumn = lines.filter { candidate in
      let other = candidate.boundingBoxNormalized
      // OCR boxes can touch or overlap by a fraction of a pixel. Column
      // centers establish reading order; requiring a positive edge gap can
      // skip the nearest column and crop directly through its glyphs.
      return candidate.isVerticalBlock && candidate.verticalCharScale >= line.verticalCharScale * 0.8
        && other.midX - b.midX > min(line.verticalCharScale, candidate.verticalCharScale) * 0.5
        && other.intersects(CGRect(x: 0, y: b.minY, width: 1, height: b.height))
    }.map(\.boundingBoxNormalized.minX).min() ?? 1
    let rubyMargin = min(line.verticalCharScale * 0.7, max(0, nextColumn - b.maxX) * 0.6)
    if line.text.count > 3 {
      // Long columns need their complete outer context. Preserve the outward
      // enclosure rather than treating a paragraph as a compact glyph sample.
      return CGRect(
        x: b.minX * imageSize.width,
        y: b.minY * imageSize.height,
        width: (b.width + rubyMargin) * imageSize.width,
        height: b.height * imageSize.height
      ).insetBy(dx: -2, dy: -2).integral.intersection(CGRect(origin: .zero, size: imageSize))
    }
    // Normalize onto the image's pixel grid before adding context. Tiny
    // coordinate noise must not add an arbitrary row/column to a small input.
    // Two pixels of padding still enclose the original subpixel glyph bounds.
    let left = (b.minX * imageSize.width).rounded()
    let top = (b.minY * imageSize.height).rounded()
    let right = ((b.maxX + rubyMargin) * imageSize.width).rounded()
    let bottom = (b.maxY * imageSize.height).rounded()
    return CGRect(
      x: left,
      y: top,
      width: right - left,
      height: bottom - top
    ).insetBy(dx: -2, dy: -2).intersection(CGRect(origin: .zero, size: imageSize))
  }

  static func preferredVerticalCorrection(
    original: String,
    candidates: [OCRResult.Line]
  ) -> (candidate: OCRResult.Line, text: String)? {
    candidates.compactMap { candidate -> (candidate: OCRResult.Line, text: String)? in
      let corrected = candidate.text == original
        ? original
        : preferredCorrection(
          original: original,
          candidate: candidate.text,
          confidence: candidate.recognitionConfidence
        )
      return corrected.map { (candidate, $0) }
    }.max {
      if $0.text.count != $1.text.count { return $0.text.count < $1.text.count }
      return $0.candidate.recognitionConfidence < $1.candidate.recognitionConfidence
    }
  }

  static func applyingVerticalCorrection(
    _ correction: (candidate: OCRResult.Line, text: String),
    to source: OCRResult.Line
  ) -> OCRResult.Line {
    let candidate = correction.candidate
    var result = source
    result.text = correction.text
    result.styleRuns = remappedStyleRuns(candidate.styleRuns, from: candidate.text, to: correction.text)
    result.spacingAnchors = correction.text == candidate.text ? candidate.spacingAnchors : []
    result.replacementPatches = candidate.replacementPatches
    result.recognitionConfidence = correction.text == source.text
      ? max(source.recognitionConfidence, candidate.recognitionConfidence)
      : candidate.recognitionConfidence
    if !candidate.recognitionLanguages.isEmpty { result.recognitionLanguages = candidate.recognitionLanguages }
    return result
  }

  static func correcting(
    _ lines: [OCRResult.Line],
    in image: CGImage
  ) async throws -> [OCRResult.Line] {
    let wrapped = try await correctingShortWrappedColumns(lines, in: image)
    let lines = try await correctingVerticalColumns(wrapped, in: image)
    let inputs = lines.indices.compactMap { index in
      input(for: lines[index], index: index, image: image)
    }
    guard !inputs.isEmpty else { return lines }

    var recognizedCorrections = [Int: Candidate]()
    for start in stride(from: 0, to: inputs.count, by: maximumBatchSize) {
      let end = min(inputs.count, start + maximumBatchSize)
      recognizedCorrections.merge(
        try await corrections(in: Array(inputs[start ..< end])),
        uniquingKeysWith: { current, candidate in
          quality(candidate, comparedWith: lines[candidate.lineIndex].text)
            > quality(current, comparedWith: lines[current.lineIndex].text)
            ? candidate
            : current
        }
      )
    }

    var result = lines
    var correctionCount = 0
    for (index, candidate) in recognizedCorrections {
      let originalText = result[index].text
      guard
        let corrected = preferredCorrection(
          original: originalText,
          candidate: candidate.text,
          confidence: candidate.confidence
        )
      else { continue }
      result[index].text = corrected
      result[index].styleRuns = remappedStyleRuns(
        result[index].styleRuns,
        from: originalText,
        to: corrected
      )
      correctionCount += 1
    }
    if correctionCount > 0 {
      Log.ocr.debug(
        "Base-glyph OCR corrected \(correctionCount, privacy: .public) Japanese rows"
      )
    }
    return result
  }

  static func preferredCorrection(
    original: String,
    candidate: String,
    confidence: Float,
    independentlyConfirmed: Bool = false
  ) -> String? {
    let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !original.isEmpty, !candidate.isEmpty, original != candidate else { return nil }
    let originalLetters = original.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
    let candidateLetters = candidate.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
    guard !originalLetters.elementsEqual(candidateLetters) else { return nil }
    let acceptsCompactHanCorrection = confidence >= 0.3
      && original.count <= 4
      && candidate.count == original.count
      && containsHan(original)
      && containsHan(candidate)
    guard confidence >= 0.45 || acceptsCompactHanCorrection || independentlyConfirmed else { return nil }
    guard containsHan(original) || confidence >= 0.9 && containsHan(candidate) else {
      return nil
    }
    let ratio = Double(candidate.count) / Double(max(1, original.count))
    guard ratio >= 0.6, ratio <= 1.5 else { return nil }
    // Cropping can simply omit the top of an otherwise correct glyph. A pure
    // deletion is not evidence that the base pass improved the transcript.
    guard !isSubsequence(candidate, of: original) else { return nil }
    let similarity = editSimilarity(original, candidate)
    guard similarity >= 0.42 || confidence >= 0.9 || acceptsCompactHanCorrection else {
      return nil
    }
    return preservingOriginalKana(in: candidate, comparedWith: original)
  }

  static func remappedStyleRuns(
    _ runs: [OverlaySourceStyleRun],
    from original: String,
    to corrected: String
  ) -> [OverlaySourceStyleRun] {
    let original = original as NSString
    let corrected = corrected as NSString
    var occupied = [NSRange]()
    return runs.compactMap { run in
      guard NSMaxRange(run.range) <= original.length else { return nil }
      let token = original.substring(with: run.range)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty else { return nil }
      var candidates = [NSRange]()
      var searchLocation = 0
      while searchLocation < corrected.length {
        let search = NSRange(
          location: searchLocation,
          length: corrected.length - searchLocation
        )
        let match = corrected.range(
          of: token,
          options: [.caseInsensitive, .widthInsensitive],
          range: search
        )
        guard match.location != NSNotFound else { break }
        if !occupied.contains(where: { NSIntersectionRange($0, match).length > 0 }) {
          candidates.append(match)
        }
        searchLocation = NSMaxRange(match)
      }
      guard !candidates.isEmpty else { return nil }
      let sourceMidpoint = Double(run.range.location * 2 + run.range.length)
        / Double(max(1, original.length * 2))
      guard
        let match = candidates.min(by: { lhs, rhs in
          let lhsMidpoint = Double(lhs.location * 2 + lhs.length)
            / Double(max(1, corrected.length * 2))
          let rhsMidpoint = Double(rhs.location * 2 + rhs.length)
            / Double(max(1, corrected.length * 2))
          return abs(lhsMidpoint - sourceMidpoint) < abs(rhsMidpoint - sourceMidpoint)
        })
      else { return nil }
      occupied.append(match)
      var result = run
      result.range = match
      return result
    }
  }

  /// A separate small upper ink band and an intervening blank band are
  /// evidence of ruby. Merely being a large Japanese row is not evidence.
  static func baseBandStart(rowInk: [Int]) -> CGFloat? {
    let height = rowInk.count
    guard height >= 24, let peak = rowInk.max(), peak > 0 else { return nil }
    let threshold = max(1, peak / 20)
    let occupied = rowInk.map { $0 > threshold }
    let minimumGap = max(2, height / 16)
    var start = height / 6
    while start < height / 2 {
      guard !occupied[start] else { start += 1
        continue
      }
      var end = start
      while end < height, !occupied[end] { end += 1 }
      let upper = occupied[..<start].count(where: { $0 })
      let lower = occupied[end...].count(where: { $0 })
      if
        end - start >= minimumGap,
        upper >= max(5, height / 8), lower >= height / 3,
        upper * 4 <= lower * 3, end < height / 2
      {
        return CGFloat(max(0, end - 1)) / CGFloat(height)
      }
      start = end + 1
    }
    return nil
  }

  /// Upright Japanese glyphs do not rotate with their vertical reading axis.
  /// Decode the same observed glyphs in horizontal order; ownership stays in
  /// the original two source columns when the transcript returns to layout.
  static func wrappedColumnStrip(_ columns: [OCRResult.Line], image: CGImage) -> CGImage? {
    var cells = [CGImage]()
    let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    for column in columns.sorted(by: { $0.boundingBoxNormalized.midX > $1.boundingBoxNormalized.midX }) {
      let box = column.boundingBoxNormalized
      let advance = column.verticalCharScale * CGFloat(image.width)
      guard advance >= 8 else { return nil }
      let count = Int((box.height * CGFloat(image.height) / advance).rounded())
      guard (1...24).contains(count), cells.count + count <= 32 else { return nil }
      for index in 0..<count {
        let rect = CGRect(
          x: box.minX * CGFloat(image.width),
          y: box.minY * CGFloat(image.height) + CGFloat(index) * advance,
          width: box.width * CGFloat(image.width),
          height: min(
            advance,
            box.height * CGFloat(image.height) - CGFloat(index) * advance
          )
        )
        .insetBy(dx: -2, dy: 0).integral.intersection(canvas)
        guard let cell = image.cropping(to: rect) else { return nil }
        cells.append(cell)
      }
    }
    let pitch = Int(ceil(columns.map { $0.verticalCharScale * CGFloat(image.width) }.max() ?? 0))
    guard
      let cellWidth = cells.map(\.width).max(), let cellHeight = cells.map(\.height).max(),
      let context = CGContext(
        data: nil,
        width: pitch * cells.count + cellWidth,
        height: cellHeight + 4,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    for (index, cell) in cells.enumerated() {
      guard
        let glyph = CGContext(
          data: nil,
          width: cell.width,
          height: cell.height,
          bitsPerComponent: 8,
          bytesPerRow: cell.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let raw = glyph.data
      else { return nil }
      glyph.draw(cell, in: CGRect(x: 0, y: 0, width: cell.width, height: cell.height))
      let bytes = raw.assumingMemoryBound(to: UInt8.self)
      let background = (Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])) / 3
      // Transparent normalized ink lets neighboring glyphs keep their real
      // advance without an oversized OCR rectangle introducing word spaces.
      for pixel in 0..<(cell.width * cell.height) {
        let offset = pixel * 4
        let luminance = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
        let alpha = min(255, max(0, abs(luminance - background) - 20) * 3)
        bytes[offset] = 0
        bytes[offset + 1] = 0
        bytes[offset + 2] = 0
        bytes[offset + 3] = UInt8(alpha)
      }
      guard let ink = glyph.makeImage() else { return nil }
      context.draw(ink, in: CGRect(x: index * pitch, y: 2, width: cell.width, height: cell.height))
    }
    return context.makeImage()
  }

  // MARK: Private

  private struct Input {
    var lineIndex: Int
    var original: String
    var crop: CGImage
  }

  private struct Slot {
    var lineIndex: Int
    var original: String
    var frame: CGRect
  }

  private struct Candidate {
    var lineIndex: Int
    var text: String
    var confidence: Float
    var rank: Int
  }

  private static let maximumBatchSize = 24
  private static let imageScale = 3
  private static let padding = 64

  private static func correctingShortWrappedColumns(
    _ lines: [OCRResult.Line],
    in image: CGImage
  ) async throws -> [OCRResult.Line] {
    var result = lines
    var removed = Set<Int>()
    for index in OCRVerticalColumnRecovery.shortWrappedColumnIndices(in: lines).prefix(4) {
      guard !removed.contains(index) else { continue }
      try Task.checkCancellation()
      let source = lines[index]
      let box = source.boundingBoxNormalized
      let peers = lines.indices
        .filter { !removed.contains($0) && lines[$0].isVerticalBlock && lines[$0].boundingBoxNormalized.minX >= box.maxX
          && lines[$0].text.unicodeScalars
          .contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
        }
      guard let peerIndex = peers.min(by: { lines[$0].boundingBoxNormalized.minX < lines[$1].boundingBoxNormalized.minX })
      else { continue }
      let peer = lines[peerIndex]
      var tail = source
      tail.verticalCharScale = peer.verticalCharScale
      guard let strip = wrappedColumnStrip([peer, tail], image: image) else { continue }
      let fresh = try await VisionTextRecognizer.additionalText(
        in: strip,
        language: .init(code: "ja"),
        crop: CGRect(
          x: 0,
          y: 0,
          width: strip.width,
          height: strip.height
        ),
        minimumGlyphHeight: peer.verticalCharScale * CGFloat(image.width),
        preferredScale: 2
      )
      let candidates = fresh.filter { candidate in
        candidate.recognitionConfidence >= 0.45 && candidate.text.count > peer.text.count
          && candidate.text.count <= peer.text.count + 4
          && candidate.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
          && candidate.text.unicodeScalars
          .allSatisfy { (0x3000...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
            || CharacterSet.punctuationCharacters.contains($0)
          }
      }
      guard let candidate = candidates.max(by: { $0.recognitionConfidence < $1.recognitionConfidence }) else { continue }
      var repaired = peer
      repaired.text = candidate.text
      repaired.boundingBoxNormalized = peer.boundingBoxNormalized.union(box)
      repaired.isVerticalBlock = true
      repaired.rowCount = 2
      repaired.verticalCharScale = peer.verticalCharScale
      repaired.horizontalGlyphScale = 0
      repaired.orientedBox = nil
      repaired.recognitionLanguages = candidate.recognitionLanguages
      repaired.recognitionConfidence = candidate.recognitionConfidence
      repaired.styleRuns = [.init(
        range: NSRange(location: 0, length: repaired.text.utf16.count),
        box: repaired.boundingBoxNormalized
      )]
      repaired.spacingAnchors = []
      repaired.replacementPatches = (peer.replacementPatches.isEmpty
        ? [.init(box: peer.boundingBoxNormalized)]
        : peer.replacementPatches)
        + (source.replacementPatches.isEmpty ? [.init(box: box)] : source.replacementPatches)
      result[peerIndex] = repaired
      removed.insert(index)
    }
    return result.indices.compactMap { removed.contains($0) ? nil : result[$0] }
  }

  private static func correctingVerticalColumns(_ lines: [OCRResult.Line], in image: CGImage) async throws -> [OCRResult.Line] {
    let hasKana = lines.contains { $0.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) } }
    guard hasKana else { return lines }
    var result = lines
    var confirmationBudget = 4
    let indices = lines.indices.filter { index in
      let line = lines[index]
      return line.isVerticalBlock && line.text.count >= 2 && containsHan(line.text)
        && line.verticalCharScale > 0
        && (line.text.count <= 3 || line.boundingBoxNormalized.width / line.verticalCharScale >= 1.15)
    }
    for index in indices.prefix(12) {
      try Task.checkCancellation()
      let line = lines[index]
      let b = line.boundingBoxNormalized
      let crop = verticalCorrectionCrop(for: line, among: lines, imageSize: CGSize(width: image.width, height: image.height))
      let recognized = try await VisionTextRecognizer.additionalText(
        in: image,
        language: .init(code: "ja"),
        crop: crop,
        minimumGlyphHeight: line
          .verticalCharScale * CGFloat(image.width),
        preferredScale: 2
      )
      let observations = OCRResult(lines: recognized).absorbingRubyAnnotations().lines
      let fragments = OCRVerticalColumnRecovery.fragments(for: line, candidates: observations)
      if !fragments.isEmpty {
        let combined = try await OCRVerticalColumnRecovery.confirmedColumn(fragments) { fragment in
          guard confirmationBudget > 0 else { return nil }
          confirmationBudget -= 1
          let b = fragment.boundingBoxNormalized
          let crop = CGRect(
            x: b.minX * CGFloat(image.width),
            y: b.minY * CGFloat(image.height),
            width: b.width * CGFloat(image.width),
            height: b.height * CGFloat(image.height)
          )
          .insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
          let fresh = try await VisionTextRecognizer.additionalText(
            in: image,
            language: .init(code: "ja"),
            crop: crop,
            minimumGlyphHeight: line
              .verticalCharScale * CGFloat(image.width),
            preferredScale: 2
          )
          return OCRResult(lines: fresh).absorbingRubyAnnotations().lines.first { $0.text == fragment.text }
        }
        guard let combined else {
          result[index].needsReview = true
          continue
        }
        let corrected = combined.text == line.text
          ? line.text
          : preferredCorrection(
            original: line.text,
            candidate: combined.text,
            confidence: combined.recognitionConfidence,
            independentlyConfirmed: true
          )
        guard let corrected else {
          result[index].needsReview = true
          continue
        }
        result[index] = applyingVerticalCorrection((combined, corrected), to: line)
        continue
      }
      let candidates = observations.filter {
        let intersection = b.intersection($0.boundingBoxNormalized)
        let area = $0.boundingBoxNormalized.width * $0.boundingBoxNormalized.height
        return !intersection.isNull && area > 0 && intersection.width * intersection.height / area >= 0.55
          && $0.text.count >= line.text.count / 2
          && $0.recognitionConfidence >= ($0.text == line.text ? 0.45 : max(0.45, line.recognitionConfidence))
      }
      guard let correction = preferredVerticalCorrection(original: line.text, candidates: candidates) else { continue }
      // The reread includes small pronunciation columns that the first document
      // pass may have omitted. Erase them with their base, never translate them.
      result[index] = applyingVerticalCorrection(correction, to: line)
    }
    return result
  }

  private static func input(
    for line: OCRResult.Line,
    index: Int,
    image: CGImage
  ) -> Input? {
    guard !line.isVerticalBlock, line.text.count >= 3 else { return nil }
    guard containsJapaneseText(line.text) else { return nil }
    let box = line.boundingBoxNormalized.standardized
    let pixelHeight = box.height * CGFloat(image.height)
    let pixelWidth = box.width * CGFloat(image.width)
    guard pixelHeight >= 32, pixelHeight <= 180, pixelWidth >= pixelHeight * 1.8 else {
      return nil
    }

    guard let fraction = baseBandStart(for: box, in: image) else { return nil }
    let baseBox = CGRect(
      x: max(0, box.minX - box.height * 0.08),
      y: box.minY + box.height * fraction,
      width: min(1 - box.minX, box.width + box.height * 0.16),
      height: box.height * (1 - fraction)
    )
    let imageBounds = CGRect(
      x: 0,
      y: 0,
      width: CGFloat(image.width),
      height: CGFloat(image.height)
    )
    let pixels = CGRect(
      x: baseBox.minX * CGFloat(image.width),
      y: baseBox.minY * CGFloat(image.height),
      width: baseBox.width * CGFloat(image.width),
      height: baseBox.height * CGFloat(image.height)
    ).integral.intersection(imageBounds)
    guard !pixels.isNull, !pixels.isEmpty, let crop = image.cropping(to: pixels) else {
      return nil
    }
    return Input(lineIndex: index, original: line.text, crop: crop)
  }

  private static func baseBandStart(for box: CGRect, in image: CGImage) -> CGFloat? {
    let rect = CGRect(
      x: box.minX * CGFloat(image.width),
      y: box.minY * CGFloat(image.height),
      width: box.width * CGFloat(image.width),
      height: box.height * CGFloat(image.height)
    ).integral
    guard
      let crop = image.cropping(to: rect),
      let context = CGContext(
        data: nil,
        width: crop.width,
        height: crop.height,
        bitsPerComponent: 8,
        bytesPerRow: crop.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    guard let data = context.data else { return nil }
    defer { withExtendedLifetime(context) { } }
    let pixels = data.bindMemory(to: UInt8.self, capacity: crop.width * crop.height * 4)
    // Median border brightness is robust to a few glyphs touching the crop.
    let border = (0..<crop.width).flatMap { x in [Int(pixels[x * 4]), Int(pixels[((crop.height - 1) * crop.width + x) * 4])] }
      .sorted()
    let background = border[border.count / 2]
    let rows = (0..<crop.height).map { y in
      (0..<crop.width).count { x in abs(Int(pixels[(y * crop.width + x) * 4]) - background) >= 40 }
    }
    return baseBandStart(rowInk: rows)
  }

  private static func corrections(in inputs: [Input]) async throws -> [Int: Candidate] {
    guard let sheet = contactSheet(for: inputs) else { return [:] }
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = [Locale.Language(identifier: "ja-JP")]
    request.usesLanguageCorrection = true
    try VisionTextRecognizer.configure(&request)
    let observations = try await request.perform(on: sheet.image)

    var candidates = [Int: [Candidate]]()
    for observation in observations {
      let box = observation.boundingRegion.boundingBox.cgRect
      let center = CGPoint(
        x: box.midX * CGFloat(sheet.image.width),
        y: box.midY * CGFloat(sheet.image.height)
      )
      guard
        let slot = sheet.slots.first(where: {
          $0.frame.insetBy(dx: -CGFloat(padding), dy: -CGFloat(padding) / 2).contains(center)
        })
      else { continue }
      for (rank, recognized) in observation.topCandidates(3).enumerated() {
        candidates[slot.lineIndex, default: []].append(Candidate(
          lineIndex: slot.lineIndex,
          text: recognized.string,
          confidence: recognized.confidence,
          rank: rank
        ))
      }
    }

    return candidates.compactMapValues { values in
      guard let first = values.first else { return nil }
      return values.dropFirst().reduce(first) { best, candidate in
        quality(candidate, comparedWith: inputs.first {
          $0.lineIndex == candidate.lineIndex
        }?.original ?? "") > quality(best, comparedWith: inputs.first {
          $0.lineIndex == best.lineIndex
        }?.original ?? "")
          ? candidate
          : best
      }
    }
  }

  private static func contactSheet(for inputs: [Input]) -> (image: CGImage, slots: [Slot])? {
    let scaledSizes = inputs.map {
      CGSize(
        width: CGFloat($0.crop.width * imageScale),
        height: CGFloat($0.crop.height * imageScale)
      )
    }
    guard let maximumWidth = scaledSizes.map(\.width).max() else { return nil }
    let width = Int(ceil(maximumWidth)) + padding * 2
    let height = Int(ceil(scaledSizes.reduce(0) { $0 + $1.height }))
      + padding * (inputs.count + 1)
    guard width > 0, height > 0 else { return nil }
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

    var slots = [Slot]()
    var y = CGFloat(padding)
    for (input, size) in zip(inputs, scaledSizes) {
      let frame = CGRect(x: CGFloat(padding), y: y, width: size.width, height: size.height)
      context.interpolationQuality = .high
      context.draw(input.crop, in: frame)
      slots.append(Slot(lineIndex: input.lineIndex, original: input.original, frame: frame))
      y += size.height + CGFloat(padding)
    }
    guard let image = context.makeImage() else { return nil }
    return (image, slots)
  }

  private static func quality(_ candidate: Candidate, comparedWith original: String) -> Double {
    let similarity = editSimilarity(original, candidate.text)
    let lengthRatio = Double(candidate.text.count) / Double(max(1, original.count))
    return Double(candidate.confidence) * 100
      + min(1.5, lengthRatio) * 10
      + similarity
      - Double(candidate.rank) * 0.01
  }

  private static func editSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let lhs = Array(lhs)
    let rhs = Array(rhs)
    guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
    var previous = Array(0 ... rhs.count)
    for (lhsIndex, lhsCharacter) in lhs.enumerated() {
      var current = [lhsIndex + 1]
      current.reserveCapacity(rhs.count + 1)
      for (rhsIndex, rhsCharacter) in rhs.enumerated() {
        current.append(min(
          current[rhsIndex] + 1,
          previous[rhsIndex + 1] + 1,
          previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
        ))
      }
      previous = current
    }
    return 1 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count))
  }

  private static func isSubsequence(_ candidate: String, of original: String) -> Bool {
    var cursor = original.startIndex
    for character in candidate {
      guard let match = original[cursor...].firstIndex(of: character) else { return false }
      cursor = original.index(after: match)
    }
    return candidate.count < original.count
  }

  private static func preservingOriginalKana(in candidate: String, comparedWith original: String) -> String {
    let candidateCharacters = Array(candidate)
    let originalCharacters = Array(original)
    guard candidateCharacters.count == originalCharacters.count else { return candidate }
    return String(zip(originalCharacters, candidateCharacters).map { original, candidate in
      isKana(original) && isKana(candidate) ? original : candidate
    })
  }

  private static func isKana(_ character: Character) -> Bool {
    !character.unicodeScalars.isEmpty && character.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 0x3040 ... 0x30FF,
           0x31F0 ... 0x31FF:
        true
      default:
        false
      }
    }
  }

  private static func containsHan(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3400 ... 0x4DBF,
           0x4E00 ... 0x9FFF,
           0xF900 ... 0xFAFF,
           0x20000 ... 0x2FA1F:
        true
      default:
        false
      }
    }
  }

  private static func containsJapaneseText(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3040 ... 0x30FF,
           0x31F0 ... 0x31FF,
           0x3400 ... 0x4DBF,
           0x4E00 ... 0x9FFF,
           0xF900 ... 0xFAFF,
           0x20000 ... 0x2FA1F:
        true
      default:
        false
      }
    }
  }
}
