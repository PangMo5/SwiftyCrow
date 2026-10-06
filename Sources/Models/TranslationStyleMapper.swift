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
    var isLiteral = false

    var isSourceFragment: Bool {
      link.query == "source=pixels"
    }
  }

  struct Alignment: Equatable {
    var target: AttributedString
    var unmatched: [Span]

    var hasUnmappedSourceFragments: Bool {
      unmatched.contains(where: \.isSourceFragment)
    }
  }

  /// One auxiliary request retains the whole sentence's context instead of
  /// translating each styled word in isolation. Its wording is never displayed.
  static func contextualRequest(source: AttributedString, links: Set<URL>? = nil) -> String? {
    let plain = String(source.characters)
    let spans = sourceSpans(in: source)
    guard
      !spans.isEmpty, plain.count <= 2_000,
      plain.range(of: #"</?s\d+>"#, options: .regularExpression) == nil
    else { return nil }
    var request = ""
    for run in source.runs {
      let text = String(source.characters[run.range])
      if
        let id = spans.firstIndex(where: { $0.link == run.link }), !spans[id].isLiteral,
        links == nil || links!.contains(spans[id].link)
      {
        request += "<s\(id)>\(text)</s\(id)>"
      } else { request += text }
    }
    return request
  }

  static func ownershipRequest(source: AttributedString) -> String? {
    // One semantic phrase can be carried by paired boundaries. Several spans
    // require contextual alignment to the established prose rather than a
    // heavily tokenized request that changes the sentence itself.
    guard sourceSpans(in: source).count == 1 else { return nil }
    guard let tagged = contextualRequest(source: source) else { return nil }
    return tagged.replacingOccurrences(of: #"<s(\d+)>"#, with: " ZXQSTYLE$1OPEN ", options: .regularExpression)
      .replacingOccurrences(of: #"</s(\d+)>"#, with: " ZXQSTYLE$1CLOSE ", options: .regularExpression)
  }

  /// A structurally complete tagged translation supplies both prose and style
  /// ownership. Do not project it onto a separately reworded plain translation.
  static func contextualTranslation(source: AttributedString, response: String) -> AttributedString? {
    let tokens = try! NSRegularExpression(pattern: #"ZXQSTYLE(\d+)(OPEN|CLOSE)"#, options: .caseInsensitive)
    let original = response as NSString
    let matches = tokens.matches(in: response, range: NSRange(location: 0, length: original.length))
    var response = response
    if !matches.isEmpty {
      // RTL translation can reverse the boundary names. They delimit an owner,
      // so match complete pairs by identity rather than treating visual order
      // as a new nesting grammar.
      var seen = [String: Set<String>]()
      for match in matches {
        let id = original.substring(with: match.range(at: 1))
        let side = original.substring(with: match.range(at: 2)).uppercased()
        guard seen[id, default: []].insert(side).inserted else { return nil }
      }
      guard seen.values.allSatisfy({ $0 == ["OPEN", "CLOSE"] }) else { return nil }
      var first = Set<String>()
      var replacements = [(NSRange, String)]()
      for match in matches {
        let id = original.substring(with: match.range(at: 1))
        replacements.append((match.range, first.insert(id).inserted ? "<s\(id)>" : "</s\(id)>"))
      }
      let value = NSMutableString(string: response)
      for (range, tag) in replacements.reversed() { value.replaceCharacters(in: range, with: tag) }
      response = value as String
    }
    let spans = sourceSpans(in: source)
    guard
      spans.count == 1, spans.allSatisfy({ !$0.isLiteral && !$0.isSourceFragment }),
      let parsed = contextualSpans(response, allowed: spans.count),
      parsed.spans.count == spans.count,
      Set(parsed.spans.map(\.id)).count == spans.count
    else { return nil }
    var target = AttributedString(parsed.text)
    for span in parsed.spans {
      guard
        let range = Range(span.range, in: parsed.text),
        let lo = AttributedString.Index(range.lowerBound, within: target),
        let hi = AttributedString.Index(range.upperBound, within: target)
      else { return nil }
      target[lo..<hi].link = spans[span.id].link
    }
    let characters = target.characters
    let lower = characters.firstIndex { !$0.isWhitespace } ?? target.endIndex
    var upper = target.endIndex
    while upper > lower {
      let previous = characters.index(before: upper)
      guard characters[previous].isWhitespace else { break }
      upper = previous
    }
    return AttributedString(target[lower..<upper])
  }

  static func alignContextual(
    source: AttributedString,
    target: String,
    response: String,
    alternatives: [URL: String] = [:],
    preserving: AttributedString? = nil
  ) -> Alignment {
    let spans = sourceSpans(in: source)
    guard let parsed = contextualSpans(response, allowed: spans.count) else { return align(
      source: source,
      target: target,
      alternatives: alternatives,
      preserving: preserving
    ) }
    let contextualAlternatives = Dictionary(uniqueKeysWithValues: parsed.spans.map { (spans[$0.id].link, $0.text) })
    var result = align(
      source: source,
      target: target,
      alternatives: alternatives,
      contextualAlternatives: contextualAlternatives,
      preserving: preserving
    )
    guard !result.unmatched.isEmpty else { return result }
    let a = Array(parsed.text)
    let b = Array(target)
    guard !a.isEmpty, !b.isEmpty, max(a.count, b.count) <= 3_000 else { return result }
    let difference = b.difference(from: a)
    let removed = Set(difference.removals.map { change in
      if case .remove(let offset, _, _) = change { return offset }
      return -1
    })
    let inserted = Set(difference.insertions.map { change in
      if case .insert(let offset, _, _) = change { return offset }
      return -1
    })
    // Permit local inflection/word-choice changes only when most of the full
    // translated context agrees. No proportional painting or synonym guessing.
    guard Double(a.count - removed.count) / Double(max(a.count, b.count)) >= 0.8 else { return result }
    var correspondence = [Int: Int]()
    var i = 0
    var j = 0
    while i < a.count, j < b.count {
      if removed.contains(i) { i += 1
        continue
      }
      if inserted.contains(j) { j += 1
        continue
      }
      guard a[i] == b[j] else { return result }
      correspondence[i] = j
      i += 1
      j += 1
    }
    let targetIndices = Array(target.indices) + [target.endIndex]
    var remaining = [Span]()
    for span in result.unmatched {
      guard
        !span.isLiteral, let id = spans.firstIndex(where: { $0.link == span.link }),
        let context = parsed.spans.first(where: { $0.id == id }),
        let range = Range(context.range, in: parsed.text)
      else { remaining.append(span)
        continue
      }
      let start = parsed.text.distance(from: parsed.text.startIndex, to: range.lowerBound)
      let end = parsed.text.distance(from: parsed.text.startIndex, to: range.upperBound)
      var lower = correspondence[start] ?? (start == 0 ? 0 : correspondence[start - 1].map { $0 + 1 })
      var upper = correspondence[end] ?? (end == a.count ? b.count : correspondence[end - 1].map { $0 + 1 })
      // If a suffix/particle changes with the styled word, expand only to its
      // unchanged word boundary. Never cross whitespace into a neighboring word.
      if upper == nil {
        for offset in end..<min(a.count, end + 8) {
          if a[offset].isWhitespace || a[offset].isPunctuation {
            upper = correspondence[offset]
            break
          }
        }
      }
      if lower == nil, start > 0 {
        for offset in stride(from: start - 1, through: max(0, start - 8), by: -1) {
          if a[offset].isWhitespace || a[offset].isPunctuation {
            lower = correspondence[offset].map { $0 + 1 }
            break
          }
        }
      }
      guard
        let lower, let upper, lower >= 0, upper <= b.count, lower < upper,
        upper - lower <= max(6, (end - start) * 2), upper - lower >= max(1, (end - start) / 2),
        let lo = AttributedString.Index(targetIndices[lower], within: result.target),
        let hi = AttributedString.Index(targetIndices[upper], within: result.target),
        result.target[lo..<hi].runs.allSatisfy({ $0.link == nil })
      else { remaining.append(span)
        continue
      }
      result.target[lo..<hi].link = span.link
    }
    result.unmatched = remaining
    return result
  }

  static func align(
    source: AttributedString,
    target: String,
    alternatives: [URL: String] = [:],
    contextualAlternatives: [URL: String] = [:],
    preserving: AttributedString? = nil
  ) -> Alignment {
    let spans = sourceSpans(in: source)
    var attributedTarget = preserving.flatMap { String($0.characters) == target ? $0 : nil } ?? AttributedString(target)
    guard !spans.isEmpty, !target.isEmpty else {
      return Alignment(target: attributedTarget, unmatched: spans)
    }

    var occupied = [Range<String.Index>]()
    var anchoredLinks = Set<URL>()
    for run in attributedTarget.runs {
      guard let link = run.link else { continue }
      anchoredLinks.insert(link)
      let start = attributedTarget.characters.distance(from: attributedTarget.startIndex, to: run.range.lowerBound)
      let end = attributedTarget.characters.distance(from: attributedTarget.startIndex, to: run.range.upperBound)
      occupied.append(target.index(target.startIndex, offsetBy: start)..<target.index(target.startIndex, offsetBy: end))
    }
    var unmatched = [Span]()
    for span in spans {
      if anchoredLinks.contains(span.link) { continue }
      let terms = [
        span.text,
        span.isLiteral ? nil : alternatives[span.link],
        span.isLiteral
          ? nil
          : contextualAlternatives[span.link],
      ]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      let candidates = terms.flatMap { term in
        if span.isSourceFragment { return canonicalRanges(of: term, in: target) }
        return span.isLiteral ? ranges(of: term, in: target, options: []) : ranges(of: term, in: target)
      }
      .filter { candidate in !occupied.contains(where: { $0.overlaps(candidate) }) }
      if span.isSourceFragment, Set(candidates).count != 1 {
        unmatched.append(span)
        continue
      }
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

  /// Use native links only when their response is the same primary text.
  /// Disjoint ownership is not flattened across intervening prose.
  static func alignNativeStyles(
    source: AttributedString,
    target: String,
    native: AttributedString?,
    preserving: AttributedString?
  ) -> Alignment {
    var result = align(source: source, target: target, preserving: preserving)
    guard let native, String(native.characters) == target else { return result }
    for span in result.unmatched where !span.isLiteral {
      var ranges = [Range<String.Index>]()
      for run in native.runs where run.link == span.link {
        let start = native.characters.distance(from: native.startIndex, to: run.range.lowerBound)
        let end = native.characters.distance(from: native.startIndex, to: run.range.upperBound)
        var piece = target[target.index(target.startIndex, offsetBy: start)..<target.index(target.startIndex, offsetBy: end)]
        while let first = piece.first, first.isWhitespace || ",.;:!?،，。".contains(first) { piece.removeFirst() }
        while let last = piece.last, last.isWhitespace || ",.;:!?،，。".contains(last) { piece.removeLast() }
        guard !piece.isEmpty else { continue }
        if let previous = ranges.last, target[previous.upperBound..<piece.startIndex].allSatisfy(\.isWhitespace) {
          ranges[ranges.count - 1] = previous.lowerBound..<piece.endIndex
        } else { ranges.append(piece.startIndex..<piece.endIndex) }
      }
      guard
        ranges.count == 1,
        let lower = AttributedString.Index(ranges[0].lowerBound, within: result.target),
        let upper = AttributedString.Index(ranges[0].upperBound, within: result.target),
        result.target[lower..<upper].runs.allSatisfy({ $0.link == nil })
      else { continue }
      result.target[lower..<upper].link = span.link
    }
    return align(source: source, target: target, preserving: result.target)
  }

  // MARK: Private

  private struct ContextSpan {
    var id: Int
    var text: String
    var range: NSRange
  }

  private static let styleBrackets = Set("()[]{}<>（）［］｛｝〈〉《》「」『』【】")

  /// Match typographic variants without rewriting the displayed translation.
  /// Every normalized scalar retains its complete original grapheme range.
  private static func canonicalRanges(of needle: String, in text: String) -> [Range<String.Index>] {
    func normalized(_ value: String) -> [(scalar: Unicode.Scalar, range: NSRange)] {
      var result = [(scalar: Unicode.Scalar, range: NSRange)]()
      var offset = 0
      for character in value {
        let original = String(character)
        let range = NSRange(location: offset, length: original.utf16.count)
        offset += range.length
        for scalar in original.precomposedStringWithCompatibilityMapping.unicodeScalars {
          if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) { continue }
          let mapped: Unicode.Scalar =
            switch scalar.value {
            case 0x2010...0x2014,
                 0x2212: "-"
            case 0x2018,
                 0x2019,
                 0x2032: "'"
            case 0x201C,
                 0x201D,
                 0x2033: "\""
            case 0x2044,
                 0x2215: "/"
            default:
              if let number = Character(String(scalar)).wholeNumberValue, (0...9).contains(number) {
                Unicode.Scalar(48 + number)!
              } else { scalar }
            }
          result.append((mapped, range))
        }
      }
      return result
    }
    func identifier(_ scalar: Unicode.Scalar) -> Bool {
      (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
        || (97...122).contains(scalar.value) || scalar == "_"
    }
    let query = normalized(needle).map(\.scalar)
    let haystack = normalized(text)
    guard !query.isEmpty, haystack.count >= query.count else { return [] }
    var matches = [Range<String.Index>]()
    func touches(_ left: NSRange, _ right: NSRange) -> Bool {
      guard NSMaxRange(left) <= right.location else { return true }
      let gap = NSRange(location: NSMaxRange(left), length: right.location - NSMaxRange(left))
      guard let range = Range(gap, in: text) else { return true }
      return !text[range].unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
    }
    for start in 0...(haystack.count - query.count) {
      let end = start + query.count
      guard zip(query, haystack[start..<end]).allSatisfy({ $0 == $1.scalar }) else { continue }
      // Do not match 3-1 inside 13-10. CJK particles are not part of a
      // mathematical identifier and may directly follow a numeric expression.
      if start > 0, haystack[start - 1].range == haystack[start].range { continue }
      if end < haystack.count, haystack[end - 1].range == haystack[end].range { continue }
      if
        start > 0, identifier(query[0]), identifier(haystack[start - 1].scalar), touches(
          haystack[start - 1].range,
          haystack[start].range
        ) { continue }
      if
        end < haystack.count, identifier(query[query.count - 1]), identifier(haystack[end].scalar), touches(
          haystack[end - 1].range,
          haystack[end].range
        ) { continue }
      let range = NSRange(
        location: haystack[start].range.location,
        length: NSMaxRange(haystack[end - 1].range) - haystack[start].range.location
      )
      if let range = Range(range, in: text) { matches.append(range) }
    }
    return matches
  }

  private static func contextualSpans(_ response: String, allowed: Int) -> (text: String, spans: [ContextSpan])? {
    guard response.count <= 8_000, let regex = try? NSRegularExpression(pattern: #"<(/?)s(\d+)>"#) else { return nil }
    let input = response as NSString
    var text = ""
    var spans = [ContextSpan]()
    var cursor = 0
    var active: (id: Int, start: Int)?
    var seen = Set<Int>()
    for match in regex.matches(in: response, range: NSRange(location: 0, length: input.length)) {
      text += input.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      guard let id = Int(input.substring(with: match.range(at: 2))), id < allowed else { return nil }
      if input.substring(with: match.range(at: 1)).isEmpty {
        guard seen.insert(id).inserted else { return nil }
        // A model can omit one closing marker. Keep that span unmatched, but
        // do not discard independent, correctly delimited metadata elsewhere.
        active = (id, text.utf16.count)
      } else {
        guard let open = active, open.id == id else { return nil }
        let range = NSRange(location: open.start, length: text.utf16.count - open.start)
        guard range.length > 0 else { return nil }
        spans.append(.init(id: id, text: (text as NSString).substring(with: range), range: range))
        active = nil
      }
      cursor = NSMaxRange(match.range)
    }
    guard !spans.isEmpty else { return nil }
    text += input.substring(from: cursor)
    return (text, spans)
  }

  private static func sourceSpans(in source: AttributedString) -> [Span] {
    let count = max(1, source.characters.count)
    return source.runs.compactMap { run in
      guard let link = run.link, link.scheme == "swiftycrow-style" else { return nil }
      let lower = source.characters.distance(from: source.characters.startIndex, to: run.range.lowerBound)
      let upper = source.characters.distance(from: source.characters.startIndex, to: run.range.upperBound)
      return Span(
        link: link,
        text: String(source.characters[run.range]),
        sourceMidpoint: Double(lower + upper) / 2 / Double(count),
        isLiteral: run.inlinePresentationIntent?.contains(.code) == true
      )
    }
  }

  private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
    let exact = ranges(of: needle, in: text, options: [])
    if !exact.isEmpty { return exact }
    let folded = ranges(of: needle, in: text, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
    if !folded.isEmpty { return folded }
    return punctuationSpacedRanges(of: needle, in: text)
  }

  /// Native lexical and sentence translations can differ only in spacing
  /// around brackets. Preserve actual word separators and paragraph breaks.
  private static func punctuationSpacedRanges(of needle: String, in text: String) -> [Range<String.Index>] {
    let brackets = styleBrackets
    guard needle.contains(where: { brackets.contains($0) }), text.contains(where: { brackets.contains($0) }) else { return [] }
    let characters = Array(needle)
    func horizontalSpace(_ character: Character) -> Bool {
      character.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains)
    }
    var pattern = ""
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if horizontalSpace(character) {
        let start = index
        while index < characters.count, horizontalSpace(characters[index]) { index += 1 }
        let nextToBracket = (start > 0 && brackets.contains(characters[start - 1]))
          || (index < characters.count && brackets.contains(characters[index]))
        if !nextToBracket { pattern += #"\h++"# }
        continue
      }
      let escaped = NSRegularExpression.escapedPattern(for: String(character))
      pattern += brackets.contains(character) ? #"\h*+"# + escaped + #"\h*+"# : escaped
      index += 1
    }
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    return expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      var lower = range.lowerBound
      var upper = range.upperBound
      while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
      while lower < upper, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
      return lower < upper ? lower..<upper : nil
    }
  }

  private static func ranges(of needle: String, in text: String, options: String.CompareOptions) -> [Range<String.Index>] {
    var result = [Range<String.Index>]()
    var cursor = text.startIndex
    while
      cursor < text.endIndex,
      let range = text.range(
        of: needle,
        options: options,
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
