// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation
import NaturalLanguage

enum OCRQualityAssessment {
  /// This is a review hint, never a spelling correction. Domain terms and
  /// identifiers must not be silently rewritten to dictionary words.
  @MainActor
  static func markingUncertainText(in result: OCRResult) -> OCRResult {
    var result = result
    var dictionary = [String: Bool]()
    for i in result.lines.indices {
      let text = result.lines[i].text
      guard
        !OCRTextSemantics.isCode(text), !OCRTextSemantics.isIdentifier(text),
        LanguageDetectionClient.liveValue.detect(text, 0)?.localeLanguage.languageCode?.identifier == "en"
      else { continue }
      let tokenizer = NLTokenizer(unit: .word)
      tokenizer.string = text
      tokenizer.setLanguage(.english)
      let words = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
        .filter { $0.count >= 3 && $0.unicodeScalars.allSatisfy(CharacterSet.letters.contains) }
      guard words.count >= 6 else { continue }
      let unknown = words.count { word in
        let normalized = word.lowercased()
        if let cached = dictionary[normalized] { return cached }
        let unknown = NSSpellChecker.shared.checkSpelling(
          of: word.lowercased(),
          startingAt: 0,
          language: "en_US",
          wrap: false,
          inSpellDocumentWithTag: 0,
          wordCount: nil
        ).location != NSNotFound
        dictionary[normalized] = unknown
        return unknown
      }
      result.lines[i].needsReview = unknown >= 3 && unknown * 4 >= words.count
    }
    return result
  }
}
