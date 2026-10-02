// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

/// A compact mixed-script control can inherit the dominant page language and
/// lose its last script entirely. Re-read just that small row at a useful scale.
enum OCRLineRefiner {

  // MARK: Internal

  static func refine(
    _ lines: [OCRResult.Line],
    in image: CGImage,
    language: Language,
    recognize: (CGImage, RecognizeTextRequest) async throws -> [String] = recognize
  ) async throws -> [OCRResult.Line] {
    var result = lines
    var replacements = [Int: [OCRResult.Line]]()
    var requestCount = 0
    var surroundingLanguage: Locale.Language?
    var resolvedSurroundingLanguage = false
    for index in lines.indices where needsRefinement(lines[index]) {
      guard requestCount < 6 else { break }
      try Task.checkCancellation()
      let literal = inlinePath(in: lines[index])
      let code = OCRTextSemantics.isCode(lines[index].text)
      let syntaxSensitive = code || literal != nil
      // A short tail is ambiguous in isolation. Only reread ordinary weak
      // text when its detected script disagrees with the surrounding prose.
      if
        lines[index].recognitionConfidence < 0.25, !syntaxSensitive,
        !lines[index].text.contains(where: { "/／|".contains($0) })
      {
        guard lines[index].text.unicodeScalars.count(where: CharacterSet.letters.contains) >= 3 else { continue }
        if !resolvedSurroundingLanguage {
          surroundingLanguage = language.isAuto
            ? LanguageDetectionClient.liveValue.detect(lines.map(\.text).joined(separator: " "), 0.65)?.localeLanguage
            : language.localeLanguage
          resolvedSurroundingLanguage = true
        }
        let observed = LanguageDetectionClient.liveValue.detect(lines[index].text, 0)?.localeLanguage
        if surroundingLanguage?.script == observed?.script { continue }
      }
      let box = literal?.box ?? lines[index].boundingBoxNormalized
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
      request.usesLanguageCorrection = !syntaxSensitive
      request.automaticallyDetectsLanguage = false
      var hints = [Locale.Language]()
      if !language.isAuto { hints.append(language.localeLanguage) }
      if
        lines[index].recognitionConfidence < 0.25,
        let context = LanguageDetectionClient.liveValue.detect(
          lines.filter { $0.recognitionConfidence >= 0.6 }.map(\.text).joined(separator: " "),
          0.65
        )
      {
        hints.append(context.localeLanguage)
      }
      if
        index > 0,
        let preceding = LanguageDetectionClient.liveValue.detect(lines[index - 1].text, 0.65)?
          .localeLanguage { hints.append(preceding) }
      hints += Locale.preferredLanguages.map { Locale.Language(identifier: $0) }
      if let inferred = LanguageDetectionClient.liveValue.detect(lines[index].text, 0)?.localeLanguage { hints.append(inferred) }
      if
        literal != nil, !lines[index].text.unicodeScalars.allSatisfy(\.isASCII),
        let inferred = LanguageDetectionClient.liveValue.detect(lines[index].text, 0.65)?.localeLanguage
      {
        hints.insert(inferred, at: 0)
      }
      let supported = request.supportedRecognitionLanguages
      var resolved = [Locale.Language]()
      for hint in hints {
        if
          let match = supported.first(where: { $0.usesSameWritingSystem(as: hint) }),
          !resolved.contains(match) { resolved.append(match) }
      }
      request.recognitionLanguages = syntaxSensitive && lines[index].text.unicodeScalars.allSatisfy(\.isASCII)
        ? supported.filter { $0.languageCode?.identifier == "en" }
        : resolved
      try VisionTextRecognizer.configure(&request)
      // The budget counts actual Vision requests. Ineligible weak fragments
      // and failed crop preparation must not starve later code/mixed-script rows.
      requestCount += 1
      let rows = try await recognize(enlarged, request)
      var text = rows.joined(separator: " ")
      if let literal {
        guard OCRVisualStructure.isPath(text) || OCRTextSemantics.isFileName(text) else { continue }
        text = (lines[index].text as NSString).replacingCharacters(in: literal.range, with: text)
      }
      guard text.count >= lines[index].text.count / 2, !text.isEmpty else { continue }
      if !syntaxSensitive, let segments = splitMixedLine(lines[index], hypothesis: text) {
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
    guard !line.preservesSource else { return false }
    if
      !line.isVerticalBlock, line.recognitionConfidence < 0.25,
      line.text.contains(where: \.isLetter) { return true }
    if
      !line.isVerticalBlock, line.text.count <= 240,
      OCRTextSemantics.isCode(line.text) || inlinePath(in: line) != nil { return true }
    guard
      !line.isVerticalBlock, line.text.count <= 100, line.boundingBoxNormalized.height < 0.12,
      line.text.contains(where: { "/／|".contains($0) }), !OCRTextSemantics.isIdentifier(line.text),
      !OCRTextSemantics.isCode(line.text)
    else { return false }
    let latin = line.text.unicodeScalars.contains { (0x41...0x7A).contains($0.value) }
    let cjk = line.text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    return latin && cjk
  }

  // MARK: Private

  private static func recognize(_ image: CGImage, request: RecognizeTextRequest) async throws -> [String] {
    try await request.perform(on: image).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
      return candidate.string
    }
  }

  /// Re-read only the literal, without changing the sentence around it or
  /// feeding an extremely wide paragraph crop to the recognition model.
  private static func inlinePath(in line: OCRResult.Line) -> (range: NSRange, box: CGRect)? {
    if
      line.rowCount == 1, !line.isVerticalBlock, line.text.count <= 120,
      !line.text.contains(where: \.isWhitespace), line.text.contains("."),
      OCRTextSemantics.isIdentifier(line.text),
      line.recognitionConfidence < 0.25 || !OCRTextSemantics.isFileName(line.text)
      || !line.text.unicodeScalars.allSatisfy(\.isASCII)
    {
      return (NSRange(line.text.startIndex..<line.text.endIndex, in: line.text), line.boundingBoxNormalized)
    }
    guard
      !OCRTextSemantics.isCode(line.text),
      let range = line.text.range(of: #"(?<!\S)/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+"#, options: .regularExpression)
    else { return nil }
    let nsRange = NSRange(range, in: line.text)
    let runs = line.styleRuns.filter { NSIntersectionRange($0.range, nsRange).length > 0 }
    guard let first = runs.first else { return nil }
    return (nsRange, runs.dropFirst().reduce(first.box) { $0.union($1.box) })
  }
}
