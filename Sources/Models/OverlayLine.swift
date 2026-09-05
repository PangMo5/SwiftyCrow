// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

// MARK: - OverlaySourceLayout

enum OverlaySourceLayout: Equatable, Sendable {
  case horizontal(rows: Int)
  case vertical(characterScale: CGFloat, progression: OverlayColumnProgression)
}

// MARK: - OverlayLine

/// A recognized source region and the explicit state of the text drawn over it.
/// Geometry belongs to the source; writing flow belongs to the displayed text.
/// Keeping those contracts separate prevents pending and failed translations
/// from being mistaken for completed target-language output.
struct OverlayLine: Equatable, Identifiable, Sendable {

  // MARK: Lifecycle

  init(id: UUID, source: Source, initialContent: InitialContent = .source) {
    self.id = id
    self.source = source
    content = initialContent == .pending ? .pending : .source
  }

  // MARK: Internal

  struct Source: Equatable, Sendable {

    // MARK: Lifecycle

    init(recognized line: OCRResult.Line, language: Locale.Language) {
      let semanticAppearance = Self.semanticBaseAppearance(
        for: line.text,
        styleRuns: line.styleRuns,
        fallback: line.appearance
      )
      box = line.boundingBoxNormalized
      text = line.text
      self.language = language
      appearance = semanticAppearance
      horizontalGlyphScale = line.horizontalGlyphScale
      horizontalInkScale = line.horizontalInkScale
      horizontalLineAdvanceScale = line.horizontalLineAdvanceScale
      replacementPatches = line.replacementPatches.isEmpty
        ? [OverlaySourcePatch(box: line.boundingBoxNormalized, appearance: semanticAppearance)]
        : line.replacementPatches
      styleRuns = line.styleRuns
      alignment = line.alignment
      surface = line.surface
      if line.isVerticalBlock {
        layout = .vertical(
          characterScale: max(0, line.verticalCharScale),
          progression: OverlayTextFlowResolver.columnProgression(for: language)
        )
      } else {
        layout = .horizontal(rows: max(1, line.rowCount))
      }
    }

    // MARK: Internal

    /// Top-left origin, 0–1 normalized to the captured frame.
    var box: CGRect
    var text: String
    var language: Locale.Language
    var layout: OverlaySourceLayout
    var appearance: OverlaySourceAppearance
    var horizontalGlyphScale: CGFloat
    var horizontalInkScale: CGFloat
    var horizontalLineAdvanceScale: CGFloat
    var replacementPatches: [OverlaySourcePatch]
    var styleRuns: [OverlaySourceStyleRun]
    var alignment: OverlayTextAlignment?
    var surface: OverlaySourceSurface?

    /// Code-only labels are semantic literals, not natural-language copy. Keep
    /// their original pixels untouched so paths/keys retain exact spelling,
    /// monospace metrics, and native rounded backgrounds while also avoiding a
    /// needless translation request.
    var isProtectedLiteral: Bool {
      guard case .horizontal = layout, appearance.fontDesign == .monospaced else { return false }
      let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let words = text.split(whereSeparator: \.isWhitespace)
      guard !text.isEmpty, words.count <= 3 else { return false }
      let compact = String(text.filter { !$0.isWhitespace })
      return compact.hasPrefix(".")
        || compact.hasSuffix(":")
        || compact.contains("/")
        || compact.contains("*")
        || compact.contains("=")
    }

    /// Compact rows beginning with a colored bullet are visual metadata (for
    /// example GitHub's repository language and counts), not prose. Keeping the
    /// source pixels preserves the marker color, icon spacing, and exact numerals.
    var isProtectedVisualMetadata: Bool {
      guard case .horizontal = layout else { return false }
      let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.count <= 48 else { return false }
      guard let marker = ["•", "●", "◉", "∙"].first(where: { text.hasPrefix($0) }) else {
        return false
      }
      let value = text.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
      let words = value.split(whereSeparator: \.isWhitespace)
      guard !words.isEmpty, words.count <= 4 else { return false }
      if words.count == 1 { return true }
      return value.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
    }

    /// Removes sub-pixel Vision noise without pinning text that genuinely moved.
    /// A live capture is normally the same static pixels every tick, but Vision's
    /// boxes can wander by a few capture pixels and make the replacement visibly
    /// breathe. Keep typography stable for tiny recognition noise, but always
    /// use current geometry: damped masks reveal the original glyphs on scroll.
    func canReuseTranslation(relativeTo previous: Self, imageSize: CGSize) -> Bool {
      text == previous.text
        && language == previous.language
        && Self.hasSameOrientation(layout, previous.layout)
        && Self.centerDistance(box, previous.box, imageSize: imageSize) <= 12
        && Self.maximumEdgeDelta(box, previous.box, imageSize: imageSize) <= 24
    }

    func stabilized(relativeTo previous: Self, imageSize: CGSize) -> Self {
      guard
        text == previous.text,
        language.maximalIdentifier == previous.language.maximalIdentifier,
        Self.hasSameOrientation(layout, previous.layout),
        imageSize.width > 0,
        imageSize.height > 0,
        Self.maximumEdgeDelta(box, previous.box, imageSize: imageSize) <= 4
      else { return self }

      var result = self
      result.layout = previous.layout
      result.horizontalGlyphScale = previous.horizontalGlyphScale
      result.horizontalInkScale = previous.horizontalInkScale
      result.horizontalLineAdvanceScale = previous.horizontalLineAdvanceScale
      result.alignment = previous.alignment ?? alignment
      result.styleRuns = Self.stabilizedStyleRuns(
        styleRuns,
        previous.styleRuns
      )

      // Ink coverage sits close to the weight thresholds on anti-aliased UI
      // fonts. Keep the established weight while the sampled colors still
      // describe the same source style, but retain the current colors so a real
      // hover/theme/background change is restored accurately.
      if
        Self.colorDistance(appearance.background, previous.appearance.background) <= 0.04,
        Self.colorDistance(appearance.foreground, previous.appearance.foreground) <= 0.08
      {
        result.appearance.fontWeight = previous.appearance.fontWeight
      }

      let backgroundMatchesPrevious = Self.colorDistance(
        appearance.background,
        previous.appearance.background
      ) <= 0.04
      if surface == nil, let previousSurface = previous.surface, backgroundMatchesPrevious {
        result.surface = previousSurface
      }
      return result
    }

    /// Apple Translation 26.4+ aligns link metadata from source ranges to the
    /// corresponding target words. Private links carry only a style-run index;
    /// they are removed before rendering and are never exposed as real links.
    func attributedTextForTranslation() -> AttributedString? {
      guard !text.isEmpty, !styleRuns.isEmpty else { return nil }
      var attributed = AttributedString(text)
      var spans = [AttributedStyleSpan]()
      for (index, run) in styleRuns.enumerated() {
        guard !Self.isBoundaryPunctuationBleed(run, in: text) else { continue }
        guard
          let stringRange = Range(run.range, in: text),
          Self.shouldCarryStyle(String(text[stringRange]), appearance: run.appearance, base: appearance)
        else { continue }
        let next = AttributedStyleSpan(
          index: index,
          range: run.range,
          box: run.box,
          appearance: run.appearance
        )
        let extendsPreviousStyle = spans.last.map {
          Self.isMateriallyDifferent($0.appearance, from: appearance)
            && Self.canCoalesce($0, with: next, in: text, base: appearance)
        } ?? false
        guard
          Self.isMateriallyDifferent(run.appearance, from: appearance)
          || extendsPreviousStyle
        else { continue }
        if
          let previous = spans.last,
          Self.canCoalesce(previous, with: next, in: text, base: appearance)
        {
          spans[spans.count - 1].range = NSUnionRange(previous.range, next.range)
          spans[spans.count - 1].box = previous.box.union(next.box)
          if
            previous.appearance.fontDesign != .monospaced,
            next.appearance.fontDesign == .monospaced
          {
            spans[spans.count - 1].index = index
            spans[spans.count - 1].appearance = next.appearance
          } else if
            !previous.appearance.isUnderlined,
            next.appearance.isUnderlined
          {
            spans[spans.count - 1].index = index
            spans[spans.count - 1].appearance = next.appearance
          }
        } else {
          spans.append(next)
        }
      }
      for span in spans {
        guard
          let stringRange = Range(span.range, in: text),
          let lowerBound = AttributedString.Index(stringRange.lowerBound, within: attributed),
          let upperBound = AttributedString.Index(stringRange.upperBound, within: attributed),
          let link = URL(string: "\(Self.styleLinkScheme)://run/\(span.index)")
        else { continue }
        attributed[lowerBound ..< upperBound].link = link
      }
      return spans.isEmpty ? nil : attributed
    }

    // MARK: Fileprivate

    fileprivate static let styleLinkScheme = "swiftycrow-style"

    // MARK: Private

    private struct AttributedStyleSpan {
      var index: Int
      var range: NSRange
      var box: CGRect
      var appearance: OverlaySourceAppearance
    }

    /// A wrapped row can begin with a long bold phrase that occupies more
    /// characters than the regular prose after it. A character-weighted median
    /// then mistakes the emphasis for the row's base style, making the entire
    /// translation bold and leaving no distinct range to map. A stable trailing
    /// run of two or more regular words is stronger structural evidence of the
    /// body style than that median.
    private static func semanticBaseAppearance(
      for text: String,
      styleRuns: [OverlaySourceStyleRun],
      fallback: OverlaySourceAppearance
    ) -> OverlaySourceAppearance {
      guard fallback.fontWeight == .medium else { return fallback }
      let source = text as NSString
      let lexicalRuns = styleRuns.filter { run in
        guard
          run.range.location >= 0,
          NSMaxRange(run.range) <= source.length
        else { return false }
        return source.substring(with: run.range).unicodeScalars.contains {
          CharacterSet.alphanumerics.contains($0)
        }
      }.sorted { $0.range.location < $1.range.location }
      guard lexicalRuns.count >= 4 else { return fallback }

      var suffixStart = lexicalRuns.endIndex
      while
        suffixStart > lexicalRuns.startIndex,
        lexicalRuns[lexicalRuns.index(before: suffixStart)].appearance.fontWeight == .regular
      {
        suffixStart = lexicalRuns.index(before: suffixStart)
      }
      let suffix = Array(lexicalRuns[suffixStart...])
      let prefix = Array(lexicalRuns[..<suffixStart])
      guard
        suffix.count >= 2,
        !prefix.isEmpty,
        prefix.allSatisfy({ $0.appearance.fontWeight.rawValue >= OverlayFontWeight.medium.rawValue }),
        prefix.contains(where: { $0.appearance.fontWeight.rawValue >= OverlayFontWeight.semibold.rawValue })
      else { return fallback }

      let sharesOneTextSurface = lexicalRuns.allSatisfy {
        colorDistance($0.appearance.background, fallback.background) <= 0.06
          && colorDistance($0.appearance.foreground, fallback.foreground) <= 0.15
          && $0.appearance.fontDesign == fallback.fontDesign
      }
      guard sharesOneTextSurface, let firstSuffix = suffix.first else { return fallback }
      let suffixText = source.substring(from: firstSuffix.range.location)
      let totalVisibleLength = visibleTextLength(text)
      let suffixVisibleLength = visibleTextLength(suffixText)
      guard
        suffixVisibleLength >= 6,
        suffixVisibleLength * 4 >= totalVisibleLength
      else { return fallback }

      let totalWeight = suffix.reduce(CGFloat.zero) {
        $0 + CGFloat(max(1, $1.range.length))
      }
      var result = fallback
      result.foreground = suffix.reduce(
        OverlayColor(red: 0, green: 0, blue: 0, alpha: 1)
      ) { color, run in
        let weight = CGFloat(max(1, run.range.length)) / max(1, totalWeight)
        return OverlayColor(
          red: color.red + run.appearance.foreground.red * weight,
          green: color.green + run.appearance.foreground.green * weight,
          blue: color.blue + run.appearance.foreground.blue * weight,
          alpha: 1
        )
      }
      result.foregroundConfidence = suffix.reduce(CGFloat.zero) {
        $0 + $1.appearance.foregroundConfidence * CGFloat(max(1, $1.range.length)) / max(1, totalWeight)
      }
      result.inkCoverage = suffix.reduce(CGFloat.zero) {
        $0 + $1.appearance.inkCoverage * CGFloat(max(1, $1.range.length)) / max(1, totalWeight)
      }
      result.inkHeightScale = suffix.reduce(CGFloat.zero) {
        $0 + $1.appearance.inkHeightScale * CGFloat(max(1, $1.range.length)) / max(1, totalWeight)
      }
      result.fontWeight = .regular
      result.isUnderlined = suffix.allSatisfy(\.appearance.isUnderlined)
      return result
    }

    private static func visibleTextLength(_ text: String) -> Int {
      text.unicodeScalars.count(where: { CharacterSet.alphanumerics.contains($0) })
    }

    private static func hasSameOrientation(_ lhs: OverlaySourceLayout, _ rhs: OverlaySourceLayout) -> Bool {
      switch (lhs, rhs) {
      case (.horizontal, .horizontal),
           (.vertical, .vertical): true
      default: false
      }
    }

    private static func stabilizedStyleRuns(
      _ current: [OverlaySourceStyleRun],
      _ previous: [OverlaySourceStyleRun]
    ) -> [OverlaySourceStyleRun] {
      current.map { run in
        guard let previous = previous.first(where: { $0.range == run.range }) else { return run }
        var result = run
        if
          colorDistance(run.appearance.background, previous.appearance.background) <= 0.04,
          colorDistance(run.appearance.foreground, previous.appearance.foreground) <= 0.08
        {
          result.appearance.fontWeight = previous.appearance.fontWeight
          result.appearance.fontDesign = previous.appearance.fontDesign
          result.appearance.isUnderlined = previous.appearance.isUnderlined
        }
        return result
      }
    }

    private static func maximumEdgeDelta(_ lhs: CGRect, _ rhs: CGRect, imageSize: CGSize) -> CGFloat {
      max(
        abs(lhs.minX - rhs.minX) * imageSize.width,
        abs(lhs.maxX - rhs.maxX) * imageSize.width,
        abs(lhs.minY - rhs.minY) * imageSize.height,
        abs(lhs.maxY - rhs.maxY) * imageSize.height
      )
    }

    private static func centerDistance(_ lhs: CGRect, _ rhs: CGRect, imageSize: CGSize) -> CGFloat {
      hypot(
        (lhs.midX - rhs.midX) * imageSize.width,
        (lhs.midY - rhs.midY) * imageSize.height
      )
    }

    private static func colorDistance(_ lhs: OverlayColor, _ rhs: OverlayColor) -> CGFloat {
      max(abs(lhs.red - rhs.red), abs(lhs.green - rhs.green), abs(lhs.blue - rhs.blue))
    }

    private static func canCoalesce(
      _ lhs: AttributedStyleSpan,
      with rhs: AttributedStyleSpan,
      in text: String,
      base: OverlaySourceAppearance
    ) -> Bool {
      guard NSMaxRange(lhs.range) <= rhs.range.location else { return false }
      let gap = NSRange(
        location: NSMaxRange(lhs.range),
        length: rhs.range.location - NSMaxRange(lhs.range)
      )
      let separator = (text as NSString).substring(with: gap)
      guard !separator.contains(where: \.isNewline) else { return false }
      let technicalPunctuation = CharacterSet(charactersIn: "._/#@+:-")
      guard
        separator.unicodeScalars.allSatisfy({
          $0.properties.isWhitespace || technicalPunctuation.contains($0)
        })
      else { return false }
      let intersection = lhs.box.intersection(rhs.box)
      let minimumArea = min(
        lhs.box.width * lhs.box.height,
        rhs.box.width * rhs.box.height
      )
      let sharesVisionBox = !intersection.isNull
        && !intersection.isEmpty
        && intersection.width * intersection.height / max(0.000_001, minimumArea) >= 0.8
      let foregroundTolerance: CGFloat = sharesVisionBox ? 0.25 : 0.08
      let underlineMatches = lhs.appearance.isUnderlined == rhs.appearance.isUnderlined
      let sharedDistinctForeground = colorDistance(
        lhs.appearance.foreground,
        base.foreground
      ) >= 0.1
        && colorDistance(rhs.appearance.foreground, base.foreground) >= 0.1
      return colorDistance(lhs.appearance.background, rhs.appearance.background) <= 0.04
        && colorDistance(lhs.appearance.foreground, rhs.appearance.foreground) <= foregroundTolerance
        && abs(lhs.appearance.fontWeight.rawValue - rhs.appearance.fontWeight.rawValue) <= 1
        && (underlineMatches || sharedDistinctForeground)
    }

    private static func isBoundaryPunctuationBleed(
      _ run: OverlaySourceStyleRun,
      in text: String
    ) -> Bool {
      guard let range = Range(run.range, in: text) else { return false }
      let token = text[range]
      let sentencePunctuation = CharacterSet(charactersIn: ".,!?;")
      guard
        !token.isEmpty,
        token.unicodeScalars.allSatisfy(sentencePunctuation.contains),
        range.upperBound == text.endIndex || text[range.upperBound].isWhitespace
      else { return false }
      // A punctuation box immediately after an inline chip can sample the
      // chip fill even though the glyph belongs to the surrounding sentence.
      // Enclosing punctuation remains style-aware; terminal sentence marks
      // follow the containing line and must not become movable code spans.
      return text[..<range.lowerBound].unicodeScalars.contains {
        CharacterSet.alphanumerics.contains($0)
      }
    }

    private static func isMateriallyDifferent(
      _ candidate: OverlaySourceAppearance,
      from base: OverlaySourceAppearance
    ) -> Bool {
      colorDistance(candidate.foreground, base.foreground) >= 0.1
        || colorDistance(candidate.background, base.background) >= 0.025
        || candidate.fontDesign != base.fontDesign
        || candidate.isUnderlined != base.isUnderlined
        || candidate.fontWeight.rawValue - base.fontWeight.rawValue >= 2
    }

    private static func shouldCarryStyle(
      _ text: String,
      appearance: OverlaySourceAppearance,
      base: OverlaySourceAppearance
    ) -> Bool {
      let containsText = text.unicodeScalars.contains {
        CharacterSet.alphanumerics.contains($0)
      }
      guard !containsText else { return true }
      return Self.isEnclosingPunctuation(text)
        && colorDistance(appearance.foreground, base.foreground) >= 0.1
        || colorDistance(appearance.background, base.background) >= 0.025
        || appearance.fontDesign != base.fontDesign
        || appearance.isUnderlined != base.isUnderlined
        || appearance.fontWeight.rawValue - base.fontWeight.rawValue >= 2
    }

    private static func isEnclosingPunctuation(_ text: String) -> Bool {
      let punctuation = CharacterSet(charactersIn: "()[]{}<>（）［］｛｝〈〉《》「」『』【】")
      let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
      return !scalars.isEmpty && scalars.allSatisfy { punctuation.contains($0) }
    }

  }

  enum InitialContent: Equatable, Sendable {
    case source
    case pending
  }

  enum Content: Equatable, Sendable {
    case source
    case pending
    case translated(Translation)
    case unavailable
  }

  struct Translation: Equatable, Sendable {

    // MARK: Lifecycle

    fileprivate init(
      text: String,
      language: Locale.Language,
      sourceLayout: OverlaySourceLayout,
      styleRuns: [OverlayTextStyleRun]
    ) {
      self.text = text
      self.language = language
      self.styleRuns = styleRuns
      flow = OverlayTextFlowResolver.translatedFlow(
        text: text,
        language: language,
        replacing: sourceLayout
      )
    }

    // MARK: Internal

    let text: String
    let language: Locale.Language
    let flow: OverlayTextFlow
    let styleRuns: [OverlayTextStyleRun]

  }

  let id: UUID
  var source: Source
  private(set) var content: Content

  var displayedText: String {
    if case .translated(let translation) = content { return translation.text }
    return source.text
  }

  var displayedLanguage: Locale.Language {
    if case .translated(let translation) = content { return translation.language }
    return source.language
  }

  var textFlow: OverlayTextFlow {
    if case .translated(let translation) = content { return translation.flow }
    return OverlayTextFlowResolver.sourceFlow(language: source.language, layout: source.layout)
  }

  var translatedText: String? {
    guard case .translated(let translation) = content else { return nil }
    return translation.text
  }

  var displayedStyleRuns: [OverlayTextStyleRun] {
    guard case .translated(let translation) = content else { return [] }
    return translation.styleRuns
  }

  var isPending: Bool {
    content == .pending
  }

  var isUnavailable: Bool {
    content == .unavailable
  }

  func textFlow(prefersHorizontalTextLayout: Bool) -> OverlayTextFlow {
    guard prefersHorizontalTextLayout, case .translated = content, case .vertical = textFlow else {
      return textFlow
    }
    return OverlayTextFlowResolver.horizontalFlow(
      text: displayedText,
      language: displayedLanguage
    )
  }

  mutating func showTranslation(
    _ text: String,
    attributedText: AttributedString? = nil,
    language: Locale.Language
  ) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      content = .unavailable
      return
    }
    let styleRuns = translatedStyleRuns(in: attributedText, matching: text)
    content = .translated(Translation(
      text: text,
      language: language,
      sourceLayout: source.layout,
      styleRuns: styleRuns
    ))
  }

  mutating func showUnavailable() {
    guard content == .pending else { return }
    content = .unavailable
  }

  // MARK: Private

  private static func enclosingPair(for token: String) -> (counterpart: String, searchesBefore: Bool)? {
    switch token {
    case ")",
         "）": ("(", true)
    case "]",
         "］": ("[", true)
    case "}",
         "｝": ("{", true)
    case ">": ("<", true)
    case "〉": ("〈", true)
    case "》": ("《", true)
    case "」": ("「", true)
    case "』": ("『", true)
    case "】": ("【", true)
    case "(",
         "（": (")", false)
    case "[",
         "［": ("]", false)
    case "{",
         "｛": ("}", false)
    case "<": (">", false)
    case "〈": ("〉", false)
    case "《": ("》", false)
    case "「": ("」", false)
    case "『": ("』", false)
    case "【": ("】", false)
    default: nil
    }
  }

  private func translatedStyleRuns(
    in attributedText: AttributedString?,
    matching text: String
  ) -> [OverlayTextStyleRun] {
    guard
      let attributedText,
      String(attributedText.characters) == text
    else { return [] }

    let mapped: [OverlayTextStyleRun] = attributedText.runs.compactMap { run in
      guard
        let link = run.link,
        link.scheme == Source.styleLinkScheme,
        link.host == "run",
        let index = Int(link.lastPathComponent),
        source.styleRuns.indices.contains(index)
      else { return nil }
      let lowerOffset = attributedText.characters.distance(
        from: attributedText.characters.startIndex,
        to: run.range.lowerBound
      )
      let upperOffset = attributedText.characters.distance(
        from: attributedText.characters.startIndex,
        to: run.range.upperBound
      )
      let lowerBound = text.index(text.startIndex, offsetBy: lowerOffset)
      let upperBound = text.index(text.startIndex, offsetBy: upperOffset)
      return OverlayTextStyleRun(
        range: NSRange(lowerBound ..< upperBound, in: text),
        appearance: source.styleRuns[index].appearance
      )
    }
    return mirroredEnclosingPunctuation(in: mapped, text: text)
  }

  private func mirroredEnclosingPunctuation(
    in runs: [OverlayTextStyleRun],
    text: String
  ) -> [OverlayTextStyleRun] {
    let source = text as NSString
    var result = runs
    for run in runs {
      guard NSMaxRange(run.range) <= source.length else { continue }
      let token = source.substring(with: run.range)
      guard let pair = Self.enclosingPair(for: token) else { continue }
      let searchRange = pair.searchesBefore
        ? NSRange(location: 0, length: run.range.location)
        : NSRange(
          location: NSMaxRange(run.range),
          length: source.length - NSMaxRange(run.range)
        )
      guard searchRange.length > 0 else { continue }
      var options = NSString.CompareOptions.widthInsensitive
      if pair.searchesBefore { options.insert(.backwards) }
      let match = source.range(of: pair.counterpart, options: options, range: searchRange)
      guard
        match.location != NSNotFound,
        !result.contains(where: { NSIntersectionRange($0.range, match).length > 0 })
      else { continue }
      result.append(OverlayTextStyleRun(range: match, appearance: run.appearance))
    }
    return result.sorted { $0.range.location < $1.range.location }
  }

}
