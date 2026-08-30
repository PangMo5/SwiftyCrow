// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - TranslationStyleMapper

enum TranslationStyleMapper {

  // MARK: Internal

  struct Span: Equatable {
    var link: URL
    var text: String
    var sourceMidpoint: Double
  }

  struct Alignment: Equatable {
    var target: AttributedString
    var unmatched: [Span]
  }

  static func align(
    source: AttributedString,
    target: String,
    alternatives: [URL: String] = [:]
  ) -> Alignment {
    let spans = sourceSpans(in: source)
    guard !spans.isEmpty, !target.isEmpty else {
      return Alignment(target: AttributedString(target), unmatched: spans)
    }

    var attributedTarget = AttributedString(target)
    var occupied = [Range<String.Index>]()
    var unmatched = [Span]()
    for span in spans {
      let terms = [span.text, alternatives[span.link]]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let candidates = terms.flatMap { ranges(of: $0, in: target) }
        .filter { candidate in !occupied.contains(where: { $0.overlaps(candidate) }) }
      guard
        let match = candidates.min(by: {
          abs(midpoint(of: $0, in: target) - span.sourceMidpoint)
            < abs(midpoint(of: $1, in: target) - span.sourceMidpoint)
        })
      else {
        unmatched.append(span)
        continue
      }
      guard
        let lowerBound = AttributedString.Index(match.lowerBound, within: attributedTarget),
        let upperBound = AttributedString.Index(match.upperBound, within: attributedTarget)
      else {
        unmatched.append(span)
        continue
      }
      attributedTarget[lowerBound ..< upperBound].link = span.link
      occupied.append(match)
    }
    return Alignment(target: attributedTarget, unmatched: unmatched)
  }

  // MARK: Private

  private static func sourceSpans(in source: AttributedString) -> [Span] {
    let count = max(1, source.characters.count)
    return source.runs.compactMap { run in
      guard let link = run.link, link.scheme == "swiftycrow-style" else { return nil }
      let lower = source.characters.distance(from: source.characters.startIndex, to: run.range.lowerBound)
      let upper = source.characters.distance(from: source.characters.startIndex, to: run.range.upperBound)
      return Span(
        link: link,
        text: String(source.characters[run.range]),
        sourceMidpoint: Double(lower + upper) / 2 / Double(count)
      )
    }
  }

  private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
    var result = [Range<String.Index>]()
    var cursor = text.startIndex
    while
      cursor < text.endIndex,
      let range = text.range(
        of: needle,
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        range: cursor ..< text.endIndex
      )
    {
      result.append(range)
      cursor = range.upperBound
    }
    return result
  }

  private static func midpoint(of range: Range<String.Index>, in text: String) -> Double {
    let count = max(1, text.count)
    let lower = text.distance(from: text.startIndex, to: range.lowerBound)
    let upper = text.distance(from: text.startIndex, to: range.upperBound)
    return Double(lower + upper) / 2 / Double(count)
  }
}
