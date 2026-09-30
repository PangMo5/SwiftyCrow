// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The translator owns prose; exact code payloads remain application-owned.
/// Keep sentence context while enforcing a one-to-one marker round trip.
struct TranslationLiteralPlan: Sendable {

  // MARK: Lifecycle

  init?(_ source: AttributedString?) {
    guard let source else { return nil }
    var ranges = [Range<AttributedString.Index>]()
    for run in source.runs where run.inlinePresentationIntent?.contains(.code) == true {
      if let previous = ranges.last, previous.upperBound == run.range.lowerBound {
        ranges[ranges.count - 1] = previous.lowerBound..<run.range.upperBound
      } else { ranges.append(run.range) }
    }
    guard !ranges.isEmpty else { return nil }
    let plain = String(source.characters)
    // Native Japanese/Arabic translation can rewrite special brackets or add
    // spaces inside them. An ASCII identifier stays a single lexical token.
    var prefix = "ZXQ"
    while plain.range(of: prefix, options: .caseInsensitive) != nil { prefix += "X" }
    markerPrefix = prefix
    var cursor = source.startIndex
    var request = AttributedString()
    var values = [String: AttributedString]()
    for (index, range) in ranges.enumerated() {
      let token = "\(prefix)\(String(format: "%03d", index))XQZ"
      request += AttributedString(source[cursor..<range.lowerBound])
      request += AttributedString(token)
      values[token] = AttributedString(source[range])
      cursor = range.upperBound
    }
    request += AttributedString(source[cursor..<source.endIndex])
    requestAttributedText = request
    literals = values
  }

  // MARK: Internal

  /// Both primary translation and metadata lookup must see identical text.
  /// Nonliteral ownership links survive without tagging the placeholder itself.
  let requestAttributedText: AttributedString

  var requestText: String {
    String(requestAttributedText.characters)
  }

  func restoring(_ response: String) -> AttributedString? {
    restoring(AttributedString(response))
  }

  func restoring(_ response: AttributedString) -> AttributedString? {
    let plain = String(response.characters)
    let pattern = NSRegularExpression.escapedPattern(for: markerPrefix) + #"\d+XQZ"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    let text = plain as NSString
    let matches = regex.matches(in: plain, range: NSRange(location: 0, length: text.length))
    guard matches.count == literals.count else { return nil }
    var seen = Set<String>()
    var cursor = 0
    var output = AttributedString()
    func slice(_ range: NSRange) -> AttributedString? {
      guard
        let stringRange = Range(range, in: plain),
        let lower = AttributedString.Index(stringRange.lowerBound, within: response),
        let upper = AttributedString.Index(stringRange.upperBound, within: response)
      else { return nil }
      return AttributedString(response[lower..<upper])
    }
    for match in matches {
      let token = text.substring(with: match.range)
      guard let literal = literals[token], seen.insert(token).inserted else { return nil }
      let range = NSRange(location: cursor, length: match.range.location - cursor)
      guard
        text.substring(with: range).range(of: markerPrefix, options: .caseInsensitive) == nil,
        let prose = slice(range)
      else { return nil }
      output += prose
      output += literal
      cursor = NSMaxRange(match.range)
    }
    guard
      text.substring(from: cursor).range(of: markerPrefix, options: .caseInsensitive) == nil,
      let tail = slice(NSRange(location: cursor, length: text.length - cursor))
    else { return nil }
    output += tail
    return output
  }

  // MARK: Private

  private let markerPrefix: String
  private let literals: [String: AttributedString]
}
