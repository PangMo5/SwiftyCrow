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
      needsReview = line.needsReview
      preservesSource = line.preservesSource
      isReconstructedTextRegion = line.isReconstructedTextRegion
      box = line.boundingBoxNormalized
      imageAspectRatio = line.imageAspectRatio
      orientedBox = line.orientedBox
      rotationRadians = line.rotationRadians
      text = line.text
      recognitionContextID = line.recognitionContextID
      recognitionContextBounds = line.recognitionContextBounds
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
      rowAlignmentEvidence = OCRGeometry.horizontalAlignmentEvidence(in: line)
      surface = line.surface
      tableCell = line.tableCell
      layoutBounds = line.layoutBounds
      textFlowRegions = line.textFlowRegions
      layoutExclusions = line.layoutExclusions
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

    var needsReview = false
    var imageAspectRatio: CGFloat
    var isReconstructedTextRegion = false
    /// Top-left origin, 0–1 normalized to the captured frame.
    var box: CGRect
    var orientedBox: CGRect?
    var rotationRadians: CGFloat = 0
    var text: String
    var recognitionContextID: Int?
    var recognitionContextBounds: CGRect?
    var language: Locale.Language
    var layout: OverlaySourceLayout
    var appearance: OverlaySourceAppearance
    var horizontalGlyphScale: CGFloat
    var horizontalInkScale: CGFloat
    var horizontalLineAdvanceScale: CGFloat
    var replacementPatches: [OverlaySourcePatch]
    var styleRuns: [OverlaySourceStyleRun]
    var preservesSource: Bool
    var alignment: OverlayTextAlignment?
    /// Measured once from this capture's physical rows; independent of Vision's hint.
    var rowAlignmentEvidence: OCRGeometry.AlignmentEvidence
    var surface: OverlaySourceSurface?
    var tableCell: OCRTableCell?
    var layoutBounds: CGRect?
    var textFlowRegions = [CGRect]()
    var layoutExclusions = [CGRect]()

    var rowAlignment: OverlayTextAlignment? {
      rowAlignmentEvidence.alignment
    }

    /// Code-only labels are semantic literals, not natural-language copy. Keep
    /// their original pixels untouched so paths/keys retain exact spelling,
    /// monospace metrics, and native rounded backgrounds while also avoiding a
    /// needless translation request.
    var isProtectedLiteral: Bool {
      if preservesSource || OCRTextSemantics.isIdentifier(text) || OCRTextSemantics.isCode(text) { return true }
      guard case .horizontal = layout, appearance.fontDesign == .monospaced else { return false }
      let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let words = text.split(whereSeparator: \.isWhitespace)
      guard !text.isEmpty, words.count <= 3 else { return false }
      // A measured fixed-pitch single token is a code-style label even when
      // its spelling has no digits or punctuation. Prose remains translatable.
      if
        words.count == 1, (4...40).contains(text.count),
        text.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) { return true }
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
        && isProtectedLiteral == previous.isProtectedLiteral
        && Self.hasSameOrientation(layout, previous.layout)
        && Self.centerDistance(box, previous.box, imageSize: imageSize) <= 12
        && Self.maximumEdgeDelta(box, previous.box, imageSize: imageSize) <= 24
        // In-flight replies carry style-run indexes from the request. Identical
        // prose and literal placeholders do not imply identical index ownership.
        && attributedTextForTranslation() == previous.attributedTextForTranslation()
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
      // The layout engine prefers calibrated point size over glyph height.
      // Stabilizing only the latter left the actual displayed size oscillating.
      let currentInk = appearance.inkHeightScale > 0 ? appearance.inkHeightScale : horizontalInkScale
      let oldInk = previous.appearance.inkHeightScale > 0 ? previous.appearance.inkHeightScale : previous.horizontalInkScale
      if
        previous.appearance.fontSizeScale > 0, currentInk > 0, oldInk > 0, abs(currentInk - oldInk) * imageSize.height <= 1,
        appearance.fontDesign == previous.appearance.fontDesign
      {
        result.appearance.fontSizeScale = previous.appearance.fontSizeScale
      }
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

      // Container geometry and verified whitespace belong to the current
      // pixels. A matching background color cannot validate a previous frame's
      // surface after an adjacent control or image has appeared.
      return result
    }

    /// Encodes inferred styles for lexical/context alignment with translated
    /// words. Private links carry only a style-run index;
    /// they are removed before rendering and are never exposed as real links.
    func attributedTextForTranslation() -> AttributedString? {
      guard !text.isEmpty else { return nil }
      var attributed = AttributedString(text)
      var spans = [AttributedStyleSpan]()
      for (index, run) in styleRuns.enumerated() {
        if run.sourceFragment != nil {
          spans.append(AttributedStyleSpan(
            index: index,
            range: run.range,
            box: run.box,
            appearance: run.appearance,
            isLiteral: run.sourceFragment?.kind == .annotation
          ))
          continue
        }
        guard !Self.isBoundaryPunctuationBleed(run, in: text) else { continue }
        guard
          let stringRange = Range(run.range, in: text),
          Self.shouldCarryStyle(String(text[stringRange]), appearance: run.appearance, base: appearance)
        else { continue }
        let next = AttributedStyleSpan(
          index: index,
          range: run.range,
          box: run.box,
          appearance: run.appearance,
          isLiteral: Self.isLiteralStyle(for: String(text[stringRange]), appearance: run.appearance, base: appearance)
        )
        let extendsPreviousStyle = spans.last.map {
          styleRuns[$0.index].sourceFragment == nil && Self.isMateriallyDifferent($0.appearance, from: appearance)
            && Self.canCoalesce($0, with: next, in: text, base: appearance)
        } ?? false
        guard
          Self.isMateriallyDifferent(run.appearance, from: appearance)
          || extendsPreviousStyle
        else { continue }
        if
          let previous = spans.last,
          styleRuns[previous.index].sourceFragment == nil,
          Self.canCoalesce(previous, with: next, in: text, base: appearance)
        {
          spans[spans.count - 1].range = NSUnionRange(previous.range, next.range)
          spans[spans.count - 1].box = previous.box.union(next.box)
          spans[spans.count - 1].isLiteral = previous.isLiteral || next.isLiteral
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
          let merged = spans[spans.count - 1]
          spans[spans.count - 1].isLiteral = merged.isLiteral || Self.isLiteralStyle(
            for: (text as NSString).substring(with: merged.range),
            appearance: merged.appearance,
            base: appearance
          )
        } else {
          spans.append(next)
        }
      }
      for span in spans {
        guard
          let stringRange = Range(span.range, in: text),
          let lowerBound = AttributedString.Index(stringRange.lowerBound, within: attributed),
          let upperBound = AttributedString.Index(stringRange.upperBound, within: attributed),
          let link = URL(string: "\(Self.styleLinkScheme)://run/\(span.index)" + (styleRuns[span.index].sourceFragment == nil
              ? ""
              : "?source=pixels"))
        else { continue }
        attributed[lowerBound ..< upperBound].link = link
        if span.appearance.isItalic {
          attributed[lowerBound ..< upperBound].inlinePresentationIntent = .emphasized
        }
        if span.isLiteral {
          attributed[lowerBound ..< upperBound].inlinePresentationIntent = span.appearance.isItalic ? [.code, .emphasized] : .code
        }
      }
      let files = OCRTextSemantics.fileNameRanges(in: text)
      for range in files {
        guard
          let lower = AttributedString.Index(range.lowerBound, within: attributed),
          let upper = AttributedString.Index(range.upperBound, within: attributed)
        else { continue }
        var intent = attributed[lower..<upper].inlinePresentationIntent ?? []
        intent.insert(.code)
        attributed[lower..<upper].inlinePresentationIntent = intent
      }
      return spans.isEmpty && files.isEmpty ? nil : attributed
    }

    // MARK: Fileprivate

    fileprivate static let styleLinkScheme = "swiftycrow-style"

    // MARK: Private

    private struct AttributedStyleSpan {
      var index: Int
      var range: NSRange
      var box: CGRect
      var appearance: OverlaySourceAppearance
      var isLiteral: Bool
    }

    /// A wrapped row can begin with a long bold phrase that occupies more
    /// characters than the regular prose after it. A character-weighted median
    /// then mistakes the emphasis for the row's base style, making the entire
    /// translation bold and leaving no distinct range to map. A stable trailing
    /// run of two or more regular words is stronger structural evidence of the
    /// body style than that median, including when the emphasis is colored.
    private static func semanticBaseAppearance(
      for text: String,
      styleRuns: [OverlaySourceStyleRun],
      fallback: OverlaySourceAppearance
    ) -> OverlaySourceAppearance {
      guard fallback.fontWeight.rawValue >= OverlayFontWeight.medium.rawValue else { return fallback }
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
      let source = text as NSString
      let lhsHasText = source.substring(with: lhs.range).contains { $0.isLetter || $0.isNumber }
      let rhsHasText = source.substring(with: rhs.range).contains { $0.isLetter || $0.isNumber }
      // Punctuation and lexical text have separate weight evidence. A noisy
      // bracket or colon must not promote an adjacent word when spans merge.
      if lhsHasText != rhsHasText, lhs.appearance.fontWeight != rhs.appearance.fontWeight { return false }
      // Similar colors do not make adjacent prose part of a code literal.
      // Punctuation can still attach to its token without changing its role.
      let gap = NSRange(
        location: NSMaxRange(lhs.range),
        length: rhs.range.location - NSMaxRange(lhs.range)
      )
      let separator = (text as NSString).substring(with: gap)
      guard !separator.contains(where: \.isNewline) else { return false }
      guard lhs.isLiteral == rhs.isLiteral || !lhsHasText || !rhsHasText || !separator.contains(where: \.isWhitespace)
      else { return false }
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
      let wrapsSameColoredSpan = separator.isEmpty && sharedDistinctForeground
        && abs(lhs.box.midY - rhs.box.midY) > min(lhs.box.height, rhs.box.height) * 0.7
      return colorDistance(lhs.appearance.background, rhs.appearance.background) <= 0.04
        && lhs.appearance.isItalic == rhs.appearance.isItalic
        && colorDistance(lhs.appearance.foreground, rhs.appearance.foreground) <= foregroundTolerance
        && (abs(lhs.appearance.fontWeight.rawValue - rhs.appearance.fontWeight.rawValue) <= 1 || wrapsSameColoredSpan)
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
        || candidate.isItalic != base.isItalic
        || candidate.isUnderlined != base.isUnderlined
        || candidate.fontWeight.rawValue - base.fontWeight.rawValue >= 2
    }

    private static func isLiteralStyle(
      for value: String,
      appearance: OverlaySourceAppearance,
      base: OverlaySourceAppearance
    ) -> Bool {
      appearance.fontDesign == .monospaced
        || (value.contains(where: { $0.isLetter || $0.isNumber }) && OCRTextSemantics.isIdentifier(value))
        || (colorDistance(appearance.background, base.background) >= 0.02 && OCRTextSemantics.isAlphanumericIdentifier(value))
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
        || appearance.isItalic != base.isItalic
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
      styleSourceText: String,
      styleReferences: [StyleReference]
    ) {
      self.text = text
      self.language = language
      self.styleSourceText = styleSourceText
      self.styleReferences = styleReferences
      flow = OverlayTextFlowResolver.translatedFlow(
        text: text,
        language: language,
        replacing: sourceLayout
      )
    }

    // MARK: Internal

    struct StyleReference: Equatable, Sendable {
      var targetRange: NSRange
      var sourceRange: NSRange
    }

    let text: String
    let language: Locale.Language
    let flow: OverlayTextFlow
    let styleSourceText: String
    let styleReferences: [StyleReference]

  }

  let id: UUID
  var source: Source
  /// In-place live overlays may paint only while their source pixels still match.
  /// Translation/cache state remains available while a newer frame is recognized.
  var sourcePixelsAreCurrent = true
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

  /// An unchanged translation does not need erasure, new typography, or a new
  /// bitmap. Keep the original glyphs (including logos and exact spacing).
  var shouldReplaceSourcePixels: Bool {
    guard sourcePixelsAreCurrent, case .translated(let translation) = content else { return false }
    for run in source.styleRuns where run.sourceFragment != nil {
      guard
        translation.styleSourceText == source.text,
        translation.styleReferences
          .count(where: { $0.sourceRange == run.range && Range($0.targetRange, in: translation.text) != nil }) == 1
      else { return false }
    }
    return translation.text != source.text
  }

  var displayedStyleRuns: [OverlayTextStyleRun] {
    guard case .translated(let translation) = content, translation.styleSourceText == source.text else { return [] }
    // Restoration may complete after translation and refine source colors.
    // Retain semantic range associations, never a snapshot of old appearances.
    let runs = translation.styleReferences.compactMap { reference -> OverlayTextStyleRun? in
      guard let run = source.styleRuns.first(where: { $0.range == reference.sourceRange }) else { return nil }
      return OverlayTextStyleRun(range: reference.targetRange, appearance: run.appearance, sourceFragment: run.sourceFragment)
    }
    return mirroredEnclosingPunctuation(in: runs, text: translation.text)
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
    let styleReferences = translatedStyleReferences(in: attributedText, matching: text)
    content = .translated(Translation(
      text: text,
      language: language,
      sourceLayout: source.layout,
      styleSourceText: source.text,
      styleReferences: styleReferences
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

  private func translatedStyleReferences(
    in attributedText: AttributedString?,
    matching text: String
  ) -> [Translation.StyleReference] {
    guard
      let attributedText,
      String(attributedText.characters) == text
    else { return [] }

    return attributedText.runs.compactMap { run in
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
      return Translation.StyleReference(
        targetRange: NSRange(lowerBound ..< upperBound, in: text),
        sourceRange: source.styleRuns[index].range
      )
    }
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
