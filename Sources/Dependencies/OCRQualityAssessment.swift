// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation
import NaturalLanguage

enum OCRQualityAssessment {
  /// This is a review hint, never a spelling correction. Domain terms and
  /// identifiers must not be silently rewritten to dictionary words.
  @MainActor
  static func markingUncertainText(in result: OCRResult, language: Language = .auto) -> OCRResult {
    var result = result
    let languages = LanguageDetectionClient.liveValue.resolveSources(for: result.lines.map(\.text), configured: language)
    var dictionary = [String: Bool]()
    for i in result.lines.indices {
      let text = result.lines[i].text
      if text.contains("\u{FFFD}") {
        result.lines[i].needsReview = true
        result.lines[i].preservesSource = true
        continue
      }
      guard
        !OCRTextSemantics.isCode(text), !OCRTextSemantics.isIdentifier(text),
        !result.lines[i].preservesSource,
        let code = languages[i].localeLanguage.languageCode?.identifier,
        let spellingLanguage = NSSpellChecker.shared.availableLanguages.first(where: {
          Locale.Language(identifier: $0).languageCode?.identifier == code
        })
      else { continue }
      let tokenizer = NLTokenizer(unit: .word)
      tokenizer.string = text
      tokenizer.setLanguage(NLLanguage(rawValue: code))
      let words = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
        .filter { $0.count >= 3 && $0.unicodeScalars.allSatisfy(CharacterSet.letters.contains) }
      guard words.count >= 3 else { continue }
      func isUnknown(_ word: String) -> Bool {
        let normalized = (word as NSString).lowercased(with: Locale(identifier: spellingLanguage))
        let key = spellingLanguage + ":" + normalized
        if let cached = dictionary[key] { return cached }
        let unknown = NSSpellChecker.shared.checkSpelling(
          of: normalized,
          startingAt: 0,
          language: spellingLanguage,
          wrap: false,
          inSpellDocumentWithTag: 0,
          wordCount: nil
        ).location != NSNotFound
        dictionary[key] = unknown
        return unknown
      }
      let unknown = words.count(where: isUnknown)
      let uncertainShortLabel = words.count <= 5 && result.lines[i].recognitionConfidence < 0.55
        && words.count(where: { $0.first?.isLowercase == true && isUnknown($0) }) >= 2
      let damagedTranscript = unknown >= 3 && unknown * 4 >= words.count
      result.lines[i].needsReview = result.lines[i].needsReview
        || damagedTranscript || uncertainShortLabel
      // Spelling dictionaries cannot distinguish bad OCR from names, borrowed
      // words or romanized terms in multilingual prose. Keep this diagnostic
      // separate from pixel/translation ownership; otherwise one unfamiliar
      // clause can silently remain untranslated inside an ordinary paragraph.
    }
    return result
  }
}
