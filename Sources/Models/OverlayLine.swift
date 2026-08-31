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
      box = line.boundingBoxNormalized
      text = line.text
      self.language = language
      appearance = line.appearance
      horizontalGlyphScale = line.horizontalGlyphScale
      horizontalInkScale = line.horizontalInkScale
      horizontalLineAdvanceScale = line.horizontalLineAdvanceScale
      replacementPatches = line.replacementPatches.isEmpty
        ? [OverlaySourcePatch(box: line.boundingBoxNormalized, appearance: line.appearance)]
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
    /// breathe. Small changes use a dead band, moderate changes are damped, and
    /// a real layout/scroll jump is accepted immediately.
    func stabilized(relativeTo previous: Self, imageSize: CGSize) -> Self {
      guard
        text == previous.text,
        language.maximalIdentifier == previous.language.maximalIdentifier,
        Self.hasSameOrientation(layout, previous.layout),
        imageSize.width > 0,
        imageSize.height > 0,
        Self.maximumEdgeDelta(box, previous.box, imageSize: imageSize) <= 24
      else { return self }

      var result = self
      result.box = Self.stabilizedRect(box, previous.box, imageSize: imageSize)
      result.layout = previous.layout
      result.horizontalGlyphScale = previous.horizontalGlyphScale
      result.horizontalInkScale = previous.horizontalInkScale
      result.horizontalLineAdvanceScale = previous.horizontalLineAdvanceScale
      result.alignment = previous.alignment ?? alignment
      result.replacementPatches = Self.stabilizedPatches(
        replacementPatches,
        previous.replacementPatches,
        imageSize: imageSize
      )
      result.styleRuns = Self.stabilizedStyleRuns(
        styleRuns,
        previous.styleRuns,
        imageSize: imageSize
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
      switch (surface, previous.surface) {
      case (.some(var current), .some(let previousSurface)):
        current.box = Self.stabilizedRect(current.box, previousSurface.box, imageSize: imageSize)
        result.surface = current

      case (.none, .some(let previousSurface)) where backgroundMatchesPrevious:
        result.surface = previousSurface

      default:
        break
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
        guard Self.isMateriallyDifferent(run.appearance, from: appearance) else { continue }
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
        if
          let previous = spans.last,
          Self.canCoalesce(previous, with: next, in: text)
        {
          spans[spans.count - 1].range = NSUnionRange(previous.range, next.range)
          spans[spans.count - 1].box = previous.box.union(next.box)
          if
            previous.appearance.fontDesign != .monospaced,
            next.appearance.fontDesign == .monospaced
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

    private static func hasSameOrientation(_ lhs: OverlaySourceLayout, _ rhs: OverlaySourceLayout) -> Bool {
      switch (lhs, rhs) {
      case (.horizontal, .horizontal),
           (.vertical, .vertical): true
      default: false
      }
    }

    private static func stabilizedPatches(
      _ current: [OverlaySourcePatch],
      _ previous: [OverlaySourcePatch],
      imageSize: CGSize
    ) -> [OverlaySourcePatch] {
      guard current.count == previous.count else { return current }
      var remaining = Array(previous.indices)
      return current.map { patch in
        guard
          let match = remaining.min(by: {
            centerDistance(patch.box, previous[$0].box, imageSize: imageSize)
              < centerDistance(patch.box, previous[$1].box, imageSize: imageSize)
          })
        else { return patch }
        remaining.removeAll { $0 == match }
        var patch = patch
        patch.box = stabilizedRect(patch.box, previous[match].box, imageSize: imageSize)
        return patch
      }
    }

    private static func stabilizedStyleRuns(
      _ current: [OverlaySourceStyleRun],
      _ previous: [OverlaySourceStyleRun],
      imageSize: CGSize
    ) -> [OverlaySourceStyleRun] {
      current.map { run in
        guard let previous = previous.first(where: { $0.range == run.range }) else { return run }
        var result = run
        result.box = stabilizedRect(run.box, previous.box, imageSize: imageSize)
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

    private static func stabilizedRect(_ current: CGRect, _ previous: CGRect, imageSize: CGSize) -> CGRect {
      let delta = maximumEdgeDelta(current, previous, imageSize: imageSize)
      guard delta <= 24 else { return current }
      guard delta > 4 else { return previous }
      let currentWeight: CGFloat = 0.35
      return CGRect(
        x: previous.minX + (current.minX - previous.minX) * currentWeight,
        y: previous.minY + (current.minY - previous.minY) * currentWeight,
        width: previous.width + (current.width - previous.width) * currentWeight,
        height: previous.height + (current.height - previous.height) * currentWeight
      )
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
      in text: String
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
      return colorDistance(lhs.appearance.background, rhs.appearance.background) <= 0.04
        && colorDistance(lhs.appearance.foreground, rhs.appearance.foreground) <= foregroundTolerance
        && abs(lhs.appearance.fontWeight.rawValue - rhs.appearance.fontWeight.rawValue) <= 1
        && lhs.appearance.isUnderlined == rhs.appearance.isUnderlined
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
