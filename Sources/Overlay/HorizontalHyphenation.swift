// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreFoundation
import Foundation
import NaturalLanguage

/// Dictionary boundaries are UTF-16 insertion positions in the unchanged word.
/// The renderer draws the discretionary hyphen separately, retaining source and
/// attributed-run indices in every Core Text line.
enum HorizontalHyphenation {

  // MARK: Internal

  struct Boundary {
    let offset: Int
    let hyphen: String
  }

  static func wordRanges(in text: String, language: Locale.Language) -> [NSRange] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    if let code = language.languageCode?.identifier { tokenizer.setLanguage(NLLanguage(rawValue: code)) }
    return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { NSRange($0, in: text) }
  }

  static func boundaries(in word: String, language: Locale.Language) -> [Boundary] {
    Dictionary(language: language)?.boundaries(in: word) ?? []
  }

  static func wordBreaks(in text: String, language: Locale.Language) -> [NSRange: [Boundary]] {
    guard let dictionary = Dictionary(language: language) else { return [:] }
    let source = text as NSString
    var cached = [String: [Boundary]]()
    var result = [NSRange: [Boundary]]()
    for range in wordRanges(in: text, language: language) {
      let word = source.substring(with: range)
      let points = cached[word] ?? dictionary.boundaries(in: word)
      cached[word] = points
      if !points.isEmpty { result[range] = points }
    }
    return result
  }

  static func pieces(in words: [String], language: Locale.Language) -> [String] {
    guard let dictionary = Dictionary(language: language) else { return words }
    var cached = [String: [String]]()
    return words.flatMap { word in
      if let pieces = cached[word] { return pieces }
      let text = word as NSString
      var start = 0
      var pieces = [String]()
      for boundary in dictionary.boundaries(in: word) {
        pieces.append(text.substring(with: NSRange(location: start, length: boundary.offset - start)) + boundary.hyphen)
        start = boundary.offset
      }
      pieces.append(text.substring(from: start))
      cached[word] = pieces
      return pieces
    }
  }

  // MARK: Private

  private struct Dictionary {

    // MARK: Lifecycle

    init?(language: Locale.Language) {
      guard
        language.characterDirection == .leftToRight,
        let locale = CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: language.maximalIdentifier as CFString)),
        CFStringIsHyphenationAvailableForLocale(locale)
      else { return nil }
      self.locale = locale
    }

    // MARK: Internal

    let locale: CFLocale

    func boundaries(in word: String) -> [Boundary] {
      guard
        word.unicodeScalars.allSatisfy({ CharacterSet.letters.union(.nonBaseCharacters).contains($0) }),
        word.unicodeScalars.contains(where: { CharacterSet.lowercaseLetters.contains($0) })
      else { return [] }
      let length = word.utf16.count
      guard length > 3 else { return [] }
      let graphemeBoundaries = Set(word.indices.map { $0.utf16Offset(in: word) })
      var cursor = length
      var result = [Boundary]()
      while cursor > 0 {
        var character: UTF32Char = 0
        let point = CFStringGetHyphenationLocationBeforeIndex(
          word as CFString,
          cursor,
          CFRange(location: 0, length: length),
          0,
          locale,
          &character
        )
        guard point > 0, point < cursor else { break }
        if graphemeBoundaries.contains(point) {
          let hyphen = character > 0 ? Unicode.Scalar(character).map(String.init) : nil
          result.append(Boundary(offset: point, hyphen: hyphen ?? "‐"))
        }
        cursor = point
      }
      return result.reversed()
    }
  }
}
