// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Reconsider short words inside measured inline surfaces, using native OCR
/// alternatives plus independent pixel evidence. Prose, ownership and ranges
/// remain unchanged; the first version only permits equal-length substitutions.
enum OCRInlineGlyphRecovery {

  // MARK: Internal

  struct Span: Sendable {
    var range: NSRange
    var box: CGRect
    var surface: CGRect
    var background: OverlayColor
  }

  static func spans(in line: OCRResult.Line) -> [Span] {
    guard
      !line.preservesSource, !line.isVerticalBlock, !line.needsReview, line.tableCell == nil,
      abs(line.rotationRadians) < 0.05, line.text.split(whereSeparator: \.isWhitespace).count >= 6
    else { return [] }
    var result = [Span]()
    for patch in line.replacementPatches where patch.erasesDistinctSurface {
      let runs = line.styleRuns.filter { run in
        let ink = run.inkBox ?? run.box
        return run.sourceFragment == nil && patch.box.contains(CGPoint(x: ink.midX, y: ink.midY))
          && run.appearance.background.distance(to: line.appearance.background) >= 0.02
      }
      guard let first = runs.first else { continue }
      let range = runs.dropFirst().reduce(first.range) { NSUnionRange($0, $1.range) }
      guard
        let stringRange = Range(range, in: line.text), eligible(String(line.text[stringRange])),
        !line.styleRuns.contains(where: { run in
          NSIntersectionRange(run.range, range).length > 0 && !runs.contains(run)
        })
      else { continue }
      let box = runs.reduce(first.box) { $0.union($1.box).union($1.inkBox ?? $1.box) }
      // A style-word eraser and its measured background plate can own the same
      // text. Keep their complete surface instead of letting iteration order
      // clamp the recognition crop to the smaller observed glyph rectangle.
      if let index = result.firstIndex(where: { $0.range == range }) {
        if result[index].background.distance(to: first.appearance.background) <= 0.02 {
          result[index].surface = result[index].surface.union(patch.box)
          result[index].box = result[index].box.union(box)
        }
        continue
      }
      guard !result.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
      result.append(Span(range: range, box: box, surface: patch.box, background: first.appearance.background))
    }
    return result.sorted { $0.range.location > $1.range.location }
  }

  static func select(
    original: String,
    observed: OCRGlyphTopology.Signature,
    candidates: [VisionTextRecognizer.TextCandidate],
    references: (String) -> Set<OCRGlyphTopology.Signature> = SourceTypography.glyphTopologies
  ) -> String? {
    let originalEvidence = references(original)
    guard contradicts(originalEvidence, observed: observed) else { return nil }
    let alternatives = Set(candidates.filter {
      $0.confidence >= 0.25 && $0.text.utf16.count == original.utf16.count && eligible($0.text)
    }.map(\.text))
    let possible = alternatives.compactMap { text -> (String, Set<OCRGlyphTopology.Signature>)? in
      let values = references(text)
      return values.contains(observed) ? (text, values) : nil
    }
    guard possible.count == 1, possible[0].1 == [observed] else { return nil }
    return possible[0].0
  }

  static func recover(
    _ result: OCRResult,
    image: CGImage,
    language: Language,
    recognize: @Sendable (CGImage, CGRect, Language) async throws -> [VisionTextRecognizer.TextCandidate] = {
      try await VisionTextRecognizer.inlineCandidates(in: $0, crop: $1, language: $2)
    }
  ) async throws -> OCRResult {
    var result = result
    var requests = 0
    let size = CGSize(width: image.width, height: image.height)
    let canvas = CGRect(origin: .zero, size: size)
    func pixels(_ box: CGRect) -> CGRect {
      CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
    }
    for index in result.lines.indices {
      for span in spans(in: result.lines[index]) where requests < 4 {
        try Task.checkCancellation()
        let crop = pixels(span.box).insetBy(dx: -3, dy: -3).integral.intersection(pixels(span.surface).integral)
          .intersection(canvas)
        guard
          let imageCrop = image.cropping(to: crop),
          let observed = OCRGlyphTopology.signature(image: imageCrop, background: span.background)
        else { continue }
        let original = (result.lines[index].text as NSString).substring(with: span.range)
        let originalEvidence = SourceTypography.glyphTopologies(text: original)
        guard contradicts(originalEvidence, observed: observed) else { continue }
        let hint = language.isAuto
          ? LanguageDetectionClient.liveValue.detect(result.lines[index].text, 0.65) ?? language
          : language
        requests += 1
        let candidates = try await recognize(image, crop, hint)
        try Task.checkCancellation()
        guard let replacement = select(original: original, observed: observed, candidates: candidates) else { continue }
        result.lines[index].text = (result.lines[index].text as NSString).replacingCharacters(in: span.range, with: replacement)
        // Equal UTF-16 length retains every source geometry/range anchor. Only
        // glyph-dependent weight/size measurements need the corrected spelling.
        for runIndex in result.lines[index].styleRuns.indices {
          var run = result.lines[index].styleRuns[runIndex]
          guard NSIntersectionRange(run.range, span.range).length > 0, let ink = run.inkBox else { continue }
          let text = (result.lines[index].text as NSString).substring(with: run.range)
          if
            let measured = SourceTypography
              .measure(text: text, inkSize: pixels(ink).size, coverage: run.appearance.inkCoverage)
          {
            run.appearance.fontWeight = measured.weight
            run.appearance.fontSizeScale = measured.pointSize / size.height
          }
          result.lines[index].styleRuns[runIndex] = run
        }
        Log.ocr.debug("Optical evidence resolved an inline glyph ambiguity")
      }
    }
    return result
  }

  // MARK: Private

  private static func contradicts(
    _ references: Set<OCRGlyphTopology.Signature>,
    observed: OCRGlyphTopology.Signature
  ) -> Bool {
    // Downsampling can merge a dot into its stem or close a small counter.
    // Missing features cannot disprove the original OCR. Require positively
    // observed extra strokes/counters that every reference face contradicts.
    !references.isEmpty && references.allSatisfy {
      observed.components > $0.components || observed.holes > $0.holes
    }
  }

  private static func eligible(_ text: String) -> Bool {
    (2...16).contains(text.count) && text.unicodeScalars.allSatisfy {
      $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-./".unicodeScalars.contains($0))
    }
  }
}
