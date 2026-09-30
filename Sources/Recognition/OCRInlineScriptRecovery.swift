// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// A dominant page language can turn an embedded script into punctuation.
/// Re-recognize only suspicious, observed word regions with automatic language
/// detection, without applying the page's language correction to that crop.
enum OCRInlineScriptRecovery {

  // MARK: Internal

  struct Span {
    var range: NSRange
    var box: CGRect
  }

  static func recover(_ lines: [OCRResult.Line], image: CGImage) async throws -> [OCRResult.Line] {
    var result = lines
    var remaining = 4
    for index in lines.indices {
      let spans = suspiciousSpans(in: lines[index])
      for span in spans.reversed() where remaining > 0 {
        remaining -= 1
        try Task.checkCancellation()
        let box = span.box
        let crop = CGRect(
          x: box.minX * CGFloat(image.width),
          y: box.minY * CGFloat(image.height),
          width: box.width * CGFloat(image.width),
          height: box.height * CGFloat(image.height)
        )
        .insetBy(dx: -3, dy: -3).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let started = ContinuousClock.now
        let candidates = try await VisionTextRecognizer.additionalText(
          in: image,
          language: .auto,
          crop: crop,
          minimumGlyphHeight: box.height * CGFloat(image.height),
          preferredScale: 2,
          usesLanguageCorrection: false
        )
        Log.ocr.log("Inline script crop completed in \(started.duration(to: .now).loggedSeconds, privacy: .public)s")
        guard
          candidates.count == 1, let candidate = candidates.first,
          accepts(candidate.text, confidence: candidate.recognitionConfidence)
        else { continue }
        let old = result[index].text
        let updated = (old as NSString).replacingCharacters(in: span.range, with: candidate.text)
        result[index].text = updated
        result[index].styleRuns = replacingSpan(span, in: result[index].styleRuns, with: candidate)
        result[index].spacingAnchors = []
      }
    }
    return result
  }

  static func accepts(_ text: String, confidence: Float) -> Bool {
    // An alternative Latin spelling is not evidence of a lost script. Do not
    // rewrite numbers, paths or ordinary prose based on another hypothesis.
    confidence >= 0.5 && text.unicodeScalars.count(where: {
      isNonLatinLetter($0)
    }) >= 2 && !text.contains("\u{FFFD}")
  }

  static func suspiciousSpans(in line: OCRResult.Line) -> [Span] {
    guard
      !line.isVerticalBlock, !line.preservesSource,
      !OCRTextSemantics.isCode(line.text), !OCRTextSemantics.isIdentifier(line.text)
    else { return [] }
    let text = line.text as NSString
    var words = [Span]()
    for run in line.styleRuns.sorted(by: { $0.range.location < $1.range.location }) {
      guard NSMaxRange(run.range) <= text.length else { continue }
      if let last = words.last, last.box == run.box {
        words[words.count - 1].range = NSUnionRange(last.range, run.range)
      } else { words.append(Span(range: run.range, box: run.box)) }
    }
    let suspicious = words.filter { span in
      let value = text.substring(with: span.range)
      guard !value.unicodeScalars.contains(where: isNonLatinLetter) else { return false }
      if
        value.count > 1,
        value.range(
          of: #"^(?:\p{Latin}[\p{Latin}\p{M}]*[.,;:!?]?|[+-]?\d+(?:[.,]\d+)*%?)$"#,
          options: .regularExpression
        ) != nil { return false }
      let symbols = value.unicodeScalars
        .count { !CharacterSet.alphanumerics.contains($0) && !CharacterSet.whitespaces.contains($0) }
      let isolatedFragment = value == "&" || value == "|" || value == "[" || value == "]"
      // A lost ideograph/Hangul glyph can look like an isolated Latin stem or
      // chevron, but retains a full-width word box inside otherwise narrow prose.
      let wideFragment = value.count == 1 && line.text.split(whereSeparator: \.isWhitespace).count >= 6
        && span.box.width * line.imageAspectRatio >= span.box.height * 0.75
        && (value == "I" || value == "l" || value == "|" || value == "›" || value == "<" || value == ">")
      return isolatedFragment || wideFragment || (value.count >= 2 && symbols > 0
        && (value.contains("|") || symbols * 3 >= value.count))
    }
    var spans = [Span]()
    for span in suspicious {
      if
        let last = spans.last,
        (span.box.minX - last.box.maxX) * line.imageAspectRatio < max(span.box.height, last.box.height) * 0.7,
        span.range.location - NSMaxRange(last.range) <= 2
      {
        spans[spans.count - 1] = Span(range: NSUnionRange(last.range, span.range), box: last.box.union(span.box))
      } else { spans.append(span) }
    }
    return spans.filter { text.substring(with: $0.range).contains(where: { $0.isLetter || $0.isNumber }) }
  }

  // MARK: Private

  private static func isNonLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.letters.contains(scalar)
      && String(scalar).range(of: #"^\p{Latin}$"#, options: .regularExpression) == nil
  }

  private static func replacingSpan(
    _ span: Span,
    in runs: [OverlaySourceStyleRun],
    with candidate: OCRResult.Line
  ) -> [OverlaySourceStyleRun] {
    let delta = candidate.text.utf16.count - span.range.length
    return runs.compactMap { run in
      if NSIntersectionRange(run.range, span.range).length > 0 { return nil }
      var run = run
      if run.range.location >= NSMaxRange(span.range) { run.range.location += delta }
      return run
    } + candidate.styleRuns.map { run in
      var run = run
      run.range.location += span.range.location
      return run
    }
  }
}
