// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import DependenciesMacros
import NaturalLanguage

// MARK: - LanguageDetectionClient

/// Detects the dominant language of recognized text, so an "Auto" source can
/// resolve to a concrete language for translation.
@DependencyClient
struct LanguageDetectionClient {
  /// The dominant language of `text`, or nil if undetermined or below
  /// `minConfidence` (0...1). Short strings detect poorly, so per-line callers
  /// pass a threshold and fall back to a whole-capture detection.
  var detect: @Sendable (_ text: String, _ minConfidence: Double) -> Language? = { _, _ in nil }
}

// MARK: DependencyKey

extension LanguageDetectionClient: DependencyKey {
  static let liveValue = LanguageDetectionClient(
    detect: { text, minConfidence in
      // A foreign quotation must not select the language for a much longer
      // surrounding paragraph. Weight independently recognized sentences by
      // their actual letters, rather than letting one distinctive phrase win.
      let tokenizer = NLTokenizer(unit: .sentence)
      tokenizer.string = text
      let sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex)
      if sentences.count > 1 {
        var weights = [NLLanguage: Int]()
        var total = 0
        for range in sentences {
          let sentence = String(text[range])
          let count = sentence.unicodeScalars.count(where: CharacterSet.letters.contains)
          guard count >= 8 else { continue }
          total += count
          let recognizer = NLLanguageRecognizer()
          recognizer.processString(sentence)
          guard
            let language = recognizer.dominantLanguage,
            language != .undetermined,
            (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.65
          else { continue }
          weights[language, default: 0] += count
        }
        if
          let best = weights.max(by: { $0.value < $1.value }), total > 0,
          Double(best.value) / Double(total) >= max(0.6, minConfidence)
        {
          return Language(code: best.key.rawValue)
        }
      }
      let recognizer = NLLanguageRecognizer()
      recognizer.processString(text)
      guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
      if minConfidence > 0 {
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        guard confidence >= minConfidence else { return nil }
      }
      return Language(code: language.rawValue)
    }
  )
}

extension LanguageDetectionClient {
  /// Prefer the recognizer's language evidence when it agrees with the actual
  /// script. Native labels are not infallible (Latin code may be labeled Thai),
  /// and mixed/absent metadata still uses the text/context resolver below.
  func resolveRecognizedSources(for lines: [OCRResult.Line], configured: Language) -> [Language] {
    guard configured.isAuto else { return Array(repeating: configured, count: lines.count) }
    let contexts = Dictionary(grouping: lines.indices, by: { lines[$0].recognitionContextID })
    if contexts.count > 1 {
      var sources = Array(repeating: Language.auto, count: lines.count)
      for indices in contexts.values {
        let local = resolveRecognizedSources(for: indices.map { lines[$0] }, configured: configured)
        for (index, language) in zip(indices, local) { sources[index] = language }
      }
      return sources
    }
    var expressions = [String: NSRegularExpression]()
    let native = lines.map { line -> Language? in
      guard line.recognitionLanguages.count == 1, let code = line.recognitionLanguages.first else { return nil }
      let language = Language(code: code)
      guard let script = language.localeLanguage.script?.identifier else { return nil }
      let scripts = [
        "Jpan": ["Hani", "Hira", "Kana"],
        "Kore": ["Hang", "Hani"],
        "Hans": ["Hani"],
        "Hant": ["Hani"],
      ][script] ?? [script]
      let pattern = scripts.map { "\\p{sc=\($0)}" }.joined(separator: "|")
      let expression: NSRegularExpression
      if let cached = expressions[pattern] { expression = cached }
      else {
        guard let parsed = try? NSRegularExpression(pattern: pattern) else { return nil }
        expressions[pattern] = parsed
        expression = parsed
      }
      let letters = line.text.unicodeScalars.count(where: CharacterSet.letters.contains)
      guard letters > 0 else { return language }
      let matching = expression.numberOfMatches(in: line.text, range: NSRange(location: 0, length: line.text.utf16.count))
      // A short mixed-script label may have only one character carrying the
      // language evidence. Reject an impossible script, not legitimate mixing.
      return matching > 0 ? language : nil
    }
    if native.allSatisfy({ $0 != nil }) { return native.compactMap { $0 } }
    let inferred = resolveSources(for: lines.map(\.text), configured: configured)
    return lines.indices.map { native[$0] ?? inferred[$0] }
  }

  /// Per-text source language for an Auto capture: detect each line (with a
  /// confidence threshold) and fall back to the whole-capture dominant language
  /// for short or ambiguous lines. For an explicit source, returns it for all.
  func resolveSources(for texts: [String], configured: Language) -> [Language] {
    guard configured.isAuto else { return Array(repeating: configured, count: texts.count) }
    let prose = texts.filter { !OCRTextSemantics.isIdentifier($0) && !OCRTextSemantics.isCode($0) }
    let fallback = detect(prose.joined(separator: "\n"), 0) ?? .defaultSource
    var latinWeights = [String: Int]()
    for text in prose where text.split(whereSeparator: \.isWhitespace).count >= 3 {
      if let language = detect(text, 0.65), language.localeLanguage.script?.identifier == "Latn" {
        latinWeights[language.code, default: 0] += text.unicodeScalars.count(where: CharacterSet.letters.contains)
      }
    }
    let dominantLatin = latinWeights.max(by: { $0.value < $1.value }).map { Language(code: $0.key) }
    let shortLatinSource = fallback.localeLanguage.script?.identifier == "Latn"
      ? fallback
      : dominantLatin ?? .defaultSource
    let pageScalars = prose.joined().unicodeScalars
    let kanaCount = pageScalars.count { (0x3040...0x30FF).contains($0.value) }
    let hangulCount = pageScalars.count { (0xAC00...0xD7A3).contains($0.value) }
    return texts.map { text in
      if OCRTextSemantics.isIdentifier(text) || OCRTextSemantics.isCode(text) { return fallback }
      let scalars = text.unicodeScalars
      let latin = scalars.count { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
      let letters = scalars.count { CharacterSet.letters.contains($0) }
      let han = scalars.count { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x2FA1F).contains($0.value) }
      if letters > 0, han == letters {
        // An English dictionary can contain an independent Japanese/Chinese
        // headword. Low-confidence Han must never inherit a Latin source.
        if ["ja", "zh", "ko"].contains(fallback.localeLanguage.languageCode?.identifier ?? "") { return fallback }
        if kanaCount >= 3 { return Language(code: "ja") }
        if hangulCount >= 12 { return Language(code: "ko") }
        if let detected = detect(text, 0), ["ja", "zh", "ko"].contains(detected.localeLanguage.languageCode?.identifier ?? "") {
          return detected
        }
      }
      let isLatinText = letters >= 2 && text.unicodeScalars.filter(CharacterSet.letters.contains).allSatisfy {
        String($0).range(of: #"^\p{Latin}$"#, options: .regularExpression) != nil
      }
      let wordCount = text.split(whereSeparator: \.isWhitespace).count
      let compactCounter = wordCount <= 5 && text.contains(where: \.isNumber)
      let titledLabel = wordCount <= 5 && text.split(whereSeparator: \.isWhitespace)
        .count(where: { $0.first?.isUppercase == true })
        >= max(2, wordCount - 1)
      if isLatinText, letters < 32, wordCount <= 3 || compactCounter || titledLabel {
        // One anomalous label must not establish a new language for other
        // controls. Short UI text uses the page's established script context.
        return shortLatinSource
      }
      if let language = detect(text, 0.65) {
        if
          isLatinText, language != shortLatinSource,
          let folded = text.applyingTransform(StringTransform("Latin-ASCII"), reverse: false), folded != text,
          detect(folded, 0.9) == shortLatinSource
        {
          // Use this only as language evidence. An OCR lookalike such as a
          // dotless i must not route English prose to another model; the
          // transcript itself remains unchanged.
          return shortLatinSource
        }
        return language
      }
      // A page's dominant script cannot turn an English caption into Arabic
      // or Japanese. Ask for the best hypothesis within this actual string.
      if latin >= 3, latin == letters, let language = detect(text, 0) { return language }
      return fallback
    }
  }
}

extension DependencyValues {
  var languageDetection: LanguageDetectionClient {
    get { self[LanguageDetectionClient.self] }
    set { self[LanguageDetectionClient.self] = newValue }
  }
}
