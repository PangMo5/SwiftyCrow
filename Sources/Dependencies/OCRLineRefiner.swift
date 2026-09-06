// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

/// A compact mixed-script control can inherit the dominant page language and
/// lose its last script entirely. Re-read just that small row at a useful scale.
enum OCRLineRefiner {
  static func refine(_ lines: [OCRResult.Line], in image: CGImage, language _: Language) async throws -> [OCRResult.Line] {
    var result = lines
    var replacements = [Int: [OCRResult.Line]]()
    for index in lines.indices.filter({ needsRefinement(lines[$0]) }).prefix(6) {
      try Task.checkCancellation()
      let box = lines[index].boundingBoxNormalized
      let rect = CGRect(
        x: box.minX * CGFloat(image.width),
        y: box.minY * CGFloat(image.height),
        width: box.width * CGFloat(image.width),
        height: box.height * CGFloat(image.height)
      )
      .insetBy(dx: -3, dy: -3).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard
        let crop = image.cropping(to: rect), let context = CGContext(
          data: nil,
          width: crop.width * 3,
          height: crop.height * 3,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { continue }
      context.interpolationQuality = .high
      context.draw(crop, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
      guard let enlarged = context.makeImage() else { continue }
      var request = RecognizeTextRequest()
      request.recognitionLevel = .accurate
      let code = OCRTextSemantics.isCode(lines[index].text)
      request.usesLanguageCorrection = !code
      request.automaticallyDetectsLanguage = false
      var hints = [Locale.Language]()
      if
        index > 0,
        let preceding = LanguageDetectionClient.liveValue.detect(lines[index - 1].text, 0.65)?
          .localeLanguage { hints.append(preceding) }
      hints += Locale.preferredLanguages.map { Locale.Language(identifier: $0) }
      if let inferred = LanguageDetectionClient.liveValue.detect(lines[index].text, 0)?.localeLanguage { hints.append(inferred) }
      let supported = request.supportedRecognitionLanguages
      var resolved = [Locale.Language]()
      for hint in hints {
        if
          let match = supported.first(where: { $0.usesSameWritingSystem(as: hint) }),
          !resolved.contains(match) { resolved.append(match) }
      }
      request.recognitionLanguages = code ? [Locale.Language(identifier: "en")] : resolved
      let rows = try await request.perform(on: enlarged).compactMap { observation -> String? in
        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
        return candidate.string
      }
      let text = rows.joined(separator: " ")
      guard text.count >= lines[index].text.count / 2, !text.isEmpty else { continue }
      if !code, let segments = splitMixedLine(lines[index], hypothesis: text) {
        replacements[index] = segments
        continue
      }
      result[index].text = text
      result[index].styleRuns = JapaneseRubyOCRCorrector.remappedStyleRuns(
        lines[index].styleRuns,
        from: lines[index].text,
        to: text
      )
    }
    return result.indices.flatMap { replacements[$0] ?? [result[$0]] }
  }

  /// Keep each reliably recognized script, and use the second hypothesis only
  /// for a segment whose script was lost. Each segment retains observed range
  /// geometry, so different languages no longer share one translation session.
  static func splitMixedLine(_ line: OCRResult.Line, hypothesis: String) -> [OCRResult.Line]? {
    let pattern = try! NSRegularExpression(pattern: #"[^/／|]+|[/／|]"#)
    let source = line.text as NSString
    let matches = pattern.matches(in: line.text, range: NSRange(location: 0, length: source.length))
    let alternatives = hypothesis.split(whereSeparator: { "/／|".contains($0) })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let originals = matches.filter { !"/／|".contains(source.substring(with: $0.range)) }
    guard originals.count == alternatives.count, originals.count >= 2 else { return nil }
    var ordinal = 0
    var segments = [OCRResult.Line]()
    for match in matches {
      let original = source.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !original.isEmpty else { continue }
      var text = original
      var review = false
      if !"/／|".contains(original) {
        let alternative = alternatives[ordinal]
        ordinal += 1
        let originalIsNumber = original.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
        let addsScript = alternative.unicodeScalars
          .contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        if originalIsNumber, addsScript { text = alternative
          review = true
        }
      }
      let runs = line.styleRuns.filter { NSIntersectionRange($0.range, match.range).length > 0 }
      guard let first = runs.first else { return nil }
      let box = runs.dropFirst().reduce(first.box) { $0.union($1.box) }
      var segment = OCRResult.Line(
        boundingBoxNormalized: box,
        text: text,
        rotationRadians: line.rotationRadians,
        imageAspectRatio: line.imageAspectRatio,
        horizontalGlyphScale: line.horizontalGlyphScale,
        replacementPatches: [OverlaySourcePatch(box: box)],
        alignment: .leading
      )
      segment.preventsJoining = true
      segment.needsReview = review
      segments.append(segment)
    }
    return segments
  }

  static func needsRefinement(_ line: OCRResult.Line) -> Bool {
    if !line.isVerticalBlock, line.text.count <= 240, OCRTextSemantics.isCode(line.text) { return true }
    guard
      !line.isVerticalBlock, line.text.count <= 100, line.boundingBoxNormalized.height < 0.12,
      line.text.contains(where: { "/／|".contains($0) }), !OCRTextSemantics.isIdentifier(line.text),
      !OCRTextSemantics.isCode(line.text)
    else { return false }
    let latin = line.text.unicodeScalars.contains { (0x41...0x7A).contains($0.value) }
    let cjk = line.text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    return latin && cjk
  }
}
