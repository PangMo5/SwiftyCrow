// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Syntax is independent of sampled font appearance. OCR can misclassify a
/// monospace font, but that must never make executable source into prose.
enum OCRTextSemantics {
  /// A compact ASCII identifier mixing letters and digits on a code-like
  /// surface (for example a type or symbol), not a unit value beginning in digits.
  static func isAlphanumericIdentifier(_ text: String) -> Bool {
    text.range(of: #"^[A-Za-z_][A-Za-z_0-9]*[0-9][A-Za-z_0-9]*$"#, options: .regularExpression) != nil
  }

  static func isIndexedIdentifier(_ text: String) -> Bool {
    text.range(of: #"^[A-Za-z_][A-Za-z_0-9]*(?:\[[^\[\]\s]+\])+$"#, options: .regularExpression) != nil
  }

  /// Sentence termination remains meaningful across scripts and after a
  /// trailing citation. It is evidence for a paragraph break, not grammar repair.
  static func endsSentence(_ text: String) -> Bool {
    let unquoted = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"(?:\s*\[[\d., -]+\]|[\"'”’»」』）)])+$"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return unquoted.last.map { ".!?。！？؟۔।॥".contains($0) } == true
  }

  /// Shared by paragraph grouping, alignment and wrapping. A hierarchical
  /// section number is one marker, not prose joining adjacent menu entries.
  static func beginsListItem(_ text: String) -> Bool {
    let trimmed = text.drop(while: \Character.isWhitespace)
    guard let first = trimmed.first else { return false }
    if "•●◦▪▫‣⁃·".contains(first) { return true }
    let tokens = trimmed.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
    guard tokens.count == 2 else { return false }
    let marker = tokens[0]
    if ["-", "–", "—", "*", "+"].contains(String(marker)) { return true }
    if marker.first == "(", marker.last == ")" {
      let number = marker.dropFirst().dropLast()
      return !number.isEmpty && number.count <= 4 && number.allSatisfy(\.isNumber)
    }
    guard marker.last == "." || marker.last == ")" else { return false }
    let components = marker.dropLast().split(separator: ".", omittingEmptySubsequences: false)
    return !components.isEmpty && components.count <= 6 && components.allSatisfy {
      !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isNumber)
    }
  }

  static func isIdentifier(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if isPhoneticReference(text) { return true }
    if
      !text.isEmpty, text.count <= 10,
      text.unicodeScalars
        .allSatisfy({ CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }) { return true }
    if text.range(of: #"^(?:https?|file|ssh)://\S+$"#, options: .regularExpression) != nil { return true }
    if text.range(of: #"^(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:[/:?#]\S*)?\.?$"#, options: .regularExpression) != nil { return true }
    if
      text.range(
        of: #"^(?:MIT|(?:A|L)?GPL(?:-\d[\w.-]*)?|BSD(?:-\d[\w.-]*)?|Apache-\d[\w.-]*|MPL-\d[\w.-]*|CC0(?:-\d[\w.-]*)?)$"#,
        options: .regularExpression
      ) != nil { return true }
    if text.range(of: #"^v?\d+(?:\.\d+){1,3}(?:[-+][\w.-]+)?$"#, options: .regularExpression) != nil { return true }
    return isVersionedProductName(text)
  }

  static func isVersionedProductName(_ text: String) -> Bool {
    guard text.count <= 40, !text.contains("\n") else { return false }
    let words = text.split(whereSeparator: \.isWhitespace)
    guard let first = words.first, words.count >= 2 else { return false }
    let letters = first.unicodeScalars.filter(CharacterSet.letters.contains)
    guard
      letters.count >= 2,
      letters.allSatisfy({ $0.isASCII })
    else { return false }
    let uppercase = letters.count { CharacterSet.uppercaseLetters.contains($0) }
    let distinctiveName = uppercase == letters.count || uppercase >= 2
      || (first.first?.isLowercase == true && uppercase > 0)
    let version = words.dropFirst().contains { $0.range(of: #"^v?\d[\w.+-]*$"#, options: .regularExpression) != nil }
    return distinctiveName && version && words.dropFirst().allSatisfy { word in
      word.range(of: #"^v?\d[\w.+-]*$"#, options: .regularExpression) != nil
        || (word.first?.isUppercase == true && word.allSatisfy(\.isLetter))
    }
  }

  /// Bracketed pronunciation notation is reference data, not prose in the
  /// language suggested by its accent marks. Keep this restricted to compact
  /// records with IPA symbols or a stressed, densely accented transcription.
  static func isPhoneticReference(_ text: String) -> Bool {
    guard
      text.contains("["), text.count <= 120,
      text.split(whereSeparator: \.isWhitespace).count(where: { $0.contains(where: \.isLetter) }) <= 6,
      let regex = try? NSRegularExpression(pattern: #"\[([^\[\]\n]{2,60})\]"#)
    else { return false }
    let source = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).contains { match in
      let body = source.substring(with: match.range(at: 1))
      guard !body.contains(where: \.isWhitespace), body.contains(where: \.isLetter) else { return false }
      let scalars = body.unicodeScalars
      let phoneticSymbols = scalars.contains { (0x0250...0x02AF).contains($0.value) || [0x02C8, 0x02CC].contains($0.value) }
      let accents = body.decomposedStringWithCanonicalMapping.unicodeScalars.count {
        CharacterSet.nonBaseCharacters.contains($0)
      }
      let stressedRomanization = accents >= 3 && body.contains(where: { "\"'ˈˌ".contains($0) })
      // OCR may flatten IPA glyphs into ordinary Latin letters. An explicit
      // notation label still establishes the reference role of that record.
      let explicitIPA = text.range(of: #"(?:^|\s)IPA(?:\s|[:(])"#, options: .regularExpression) != nil
      return phoneticSymbols || stressedRomanization || explicitIPA
    }
  }

  static func isCode(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    if text.hasPrefix("//") || text.hasPrefix("#!") || text.hasPrefix("```") { return true }
    if ["{", "}", "};", "]", ");"].contains(text) { return true }
    let patterns = [
      #"^(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*="#,
      #"^(?:let|var|const|func|def|class|struct|enum|import|from)\s+[^\s]+.*(?:[=:{(]|\bimport\b)"#,
      #"^(?:if|while|for|switch|guard)\s+.*[{}=():]"#,
      #"^return\s+(?:nil|null|true|false|\w+[.(])"#,
      #"^(?:git|swift|cargo|npm|pnpm|yarn|pip|python\d*|curl|wget|brew|tuist|xcodebuild)\s+\S+"#,
    ]
    return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
  }
}
