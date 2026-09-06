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
  /// Per-text source language for an Auto capture: detect each line (with a
  /// confidence threshold) and fall back to the whole-capture dominant language
  /// for short or ambiguous lines. For an explicit source, returns it for all.
  func resolveSources(for texts: [String], configured: Language) -> [Language] {
    guard configured.isAuto else { return Array(repeating: configured, count: texts.count) }
    let prose = texts.filter { !OCRTextSemantics.isIdentifier($0) && !OCRTextSemantics.isCode($0) }
    let fallback = detect(prose.joined(separator: "\n"), 0) ?? .defaultSource
    let proseLanguages = prose.filter { $0.split(whereSeparator: \.isWhitespace).count >= 3 }.compactMap { detect($0, 0.65) }
    let latinLanguages = proseLanguages.filter { $0.localeLanguage.script?.identifier == "Latn" }
    let preferredLatin = Locale.preferredLanguages.map { Language(code: $0) }.first { preferred in
      latinLanguages.contains { $0.localeLanguage.usesSameWritingSystem(as: preferred.localeLanguage) }
    }
    let shortLatinSource = preferredLatin ?? latinLanguages.first
      ?? (fallback.localeLanguage.script?.identifier == "Latn" ? fallback : .defaultSource)
    return texts.map { text in
      if OCRTextSemantics.isIdentifier(text) || OCRTextSemantics.isCode(text) { return fallback }
      let scalars = text.unicodeScalars
      let latin = scalars.count { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
      let letters = scalars.count { CharacterSet.letters.contains($0) }
      if latin == letters, latin >= 2, latin < 12, text.split(whereSeparator: \.isWhitespace).count == 1 {
        if
          let detected = detect(text, 0.9),
          proseLanguages.contains(where: { $0.localeLanguage.usesSameWritingSystem(as: detected.localeLanguage) })
        {
          return detected
        }
        return shortLatinSource
      }
      if let language = detect(text, 0.65) { return language }
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
