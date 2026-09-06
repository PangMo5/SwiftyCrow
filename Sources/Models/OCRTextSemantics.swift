// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Syntax is independent of sampled font appearance. OCR can misclassify a
/// monospace font, but that must never make executable source into prose.
enum OCRTextSemantics {
  static func isIdentifier(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if
      !text.isEmpty, text.count <= 10,
      text.unicodeScalars
        .allSatisfy({ CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }) { return true }
    if text.range(of: #"^(?:https?|file|ssh)://\S+$"#, options: .regularExpression) != nil { return true }
    if
      text.range(
        of: #"^(?:MIT|(?:A|L)?GPL(?:-\d[\w.-]*)?|BSD(?:-\d[\w.-]*)?|Apache-\d[\w.-]*|MPL-\d[\w.-]*|CC0(?:-\d[\w.-]*)?)$"#,
        options: .regularExpression
      ) != nil { return true }
    if text.range(of: #"^v?\d+(?:\.\d+){1,3}(?:[-+][\w.-]+)?$"#, options: .regularExpression) != nil { return true }
    return false
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
