// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Attributed overlay styles")
struct OverlayAttributedStyleTests {

  // MARK: Internal

  @Test
  func appleAlignedAttributesMapSourceStylesOntoTranslatedWords() throws {
    let sourceText = "Proposal #179. Agent Skills handles reusable capabilities."
    let issueAppearance = OverlaySourceAppearance(
      background: .black,
      foreground: OverlayColor(red: 0.55, green: 0.58, blue: 0.63, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular
    )
    let linkAppearance = OverlaySourceAppearance(
      background: .black,
      foreground: OverlayColor(red: 0.18, green: 0.52, blue: 0.95, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .medium,
      isUnderlined: true
    )
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.1),
      text: sourceText,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "#179", in: sourceText),
          box: CGRect(x: 0.2, y: 0.2, width: 0.08, height: 0.1),
          appearance: issueAppearance
        ),
        OverlaySourceStyleRun(
          range: try range(of: "Agent Skills", in: sourceText),
          box: CGRect(x: 0.35, y: 0.2, width: 0.18, height: 0.1),
          appearance: linkAppearance
        ),
      ]
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )

    let request = try #require(line.source.attributedTextForTranslation())
    #expect(request.runs.compactMap(\.link).count == 2)

    let targetText = "제안 #179에 관한 내용입니다. 에이전트 스킬은 재사용할 수 있습니다."
    var target = AttributedString(targetText)
    try tag("#179에", with: "swiftycrow-style://run/0", in: &target)
    try tag("에이전트 스킬은", with: "swiftycrow-style://run/1", in: &target)
    line.showTranslation(
      targetText,
      attributedText: target,
      language: Locale.Language(identifier: "ko-KR")
    )

    let runs = line.displayedStyleRuns
    #expect(runs.count == 2)
    #expect((targetText as NSString).substring(with: runs[0].range) == "#179에")
    #expect(runs[0].appearance.foreground == issueAppearance.foreground)
    #expect((targetText as NSString).substring(with: runs[1].range) == "에이전트 스킬은")
    #expect(runs[1].appearance.foreground == linkAppearance.foreground)
    #expect(runs[1].appearance.isUnderlined)
  }

  @Test
  func literalStyleMapperAlignsTechnicalTokensWithoutRetranslatingTheLine() throws {
    var source = AttributedString("Proposal #179. Agent Skills handles reusable capabilities.")
    try tag("#179", with: "swiftycrow-style://run/0", in: &source)
    try tag("Agent Skills", with: "swiftycrow-style://run/1", in: &source)

    let alignment = TranslationStyleMapper.align(
      source: source,
      target: "제안 #179에 관한 내용입니다. Agent Skills는 재사용할 수 있습니다."
    )

    #expect(alignment.unmatched.isEmpty)
    #expect(alignment.target.runs.compactMap(\.link).count == 2)
  }

  @Test
  func adjacentCodeFragmentsMoveAsWholeVisualTokens() throws {
    let sourceText = "Runs on macOS 26 with build 2.10.0. Done."
    let base = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.42, green: 0.44, blue: 0.48, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular
    )
    let code = OverlaySourceAppearance(
      background: OverlayColor(red: 0.91, green: 0.93, blue: 0.96, alpha: 1),
      foreground: OverlayColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular,
      fontDesign: .monospaced
    )
    // The final period is intentionally given the chip appearance to model
    // Vision sampling bleed at the edge of `<code>2.10.0</code>.`.
    let fragments = ["macOS", "26", "2", "10", "0", "."]
    var cursor = 0
    let styleRuns = fragments.compactMap { fragment -> OverlaySourceStyleRun? in
      let searchRange = NSRange(location: cursor, length: (sourceText as NSString).length - cursor)
      let range = (sourceText as NSString).range(of: fragment, range: searchRange)
      guard range.location != NSNotFound else { return nil }
      cursor = NSMaxRange(range)
      return OverlaySourceStyleRun(range: range, box: .zero, appearance: code)
    }
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.1),
      text: sourceText,
      appearance: base,
      styleRuns: styleRuns
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )

    let attributedSource = try #require(line.source.attributedTextForTranslation())
    let sourceSpans: [String] = attributedSource.runs.compactMap { run in
      guard run.link != nil else { return nil }
      return String(attributedSource.characters[run.range])
    }
    #expect(sourceSpans == ["macOS 26", "2.10.0"])

    let target = "빌드 2.10.0으로 macOS 26에서 실행됩니다."
    let alignment = TranslationStyleMapper.align(source: attributedSource, target: target)
    #expect(alignment.unmatched.isEmpty)
    line.showTranslation(
      target,
      attributedText: alignment.target,
      language: Locale.Language(identifier: "ko-KR")
    )
    let targetSpans = line.displayedStyleRuns.map {
      (target as NSString).substring(with: $0.range)
    }
    #expect(targetSpans == ["2.10.0", "macOS 26"])
  }

  @Test
  func styleSpansNeverCoalesceAcrossARecoveredHardBreak() throws {
    let sourceText = "Two checks are pending.\nThe orange surface remains visible."
    let base = OverlaySourceAppearance(
      background: OverlayColor(red: 1, green: 0.94, blue: 0.84, alpha: 1),
      foreground: OverlayColor(red: 0.65, green: 0.40, blue: 0.02, alpha: 1),
      confidence: 1,
      foregroundConfidence: 0.2,
      fontWeight: .regular
    )
    var emphasized = base
    emphasized.fontWeight = .bold
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1),
      text: sourceText,
      appearance: base,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "Two checks are pending.", in: sourceText),
          box: CGRect(x: 0.1, y: 0.2, width: 0.25, height: 0.04),
          appearance: emphasized
        ),
        OverlaySourceStyleRun(
          range: try range(of: "The", in: sourceText),
          box: CGRect(x: 0.1, y: 0.25, width: 0.04, height: 0.04),
          appearance: emphasized
        ),
      ]
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "en-US")
    )

    let attributed = try #require(source.attributedTextForTranslation())
    let spans = attributed.runs.compactMap { run in
      run.link.map { _ in String(attributed.characters[run.range]) }
    }

    #expect(spans == ["Two checks are pending.", "The"])
  }

  @Test
  func leadingEmphasisUsesTheTrailingBodyAsItsBaseStyle() throws {
    let text = "Apple Translation supplies the"
    let regular = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular
    )
    var medium = regular
    medium.fontWeight = .medium
    var semibold = regular
    semibold.fontWeight = .semibold
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.08),
      text: text,
      appearance: medium,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "Apple", in: text),
          box: CGRect(x: 0.1, y: 0.2, width: 0.12, height: 0.08),
          appearance: semibold
        ),
        OverlaySourceStyleRun(
          range: try range(of: "Translation", in: text),
          box: CGRect(x: 0.23, y: 0.2, width: 0.24, height: 0.08),
          appearance: medium
        ),
        OverlaySourceStyleRun(
          range: try range(of: "supplies", in: text),
          box: CGRect(x: 0.48, y: 0.2, width: 0.18, height: 0.08),
          appearance: regular
        ),
        OverlaySourceStyleRun(
          range: try range(of: "the", in: text),
          box: CGRect(x: 0.67, y: 0.2, width: 0.08, height: 0.08),
          appearance: regular
        ),
      ]
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "en-US")
    )

    let attributed = try #require(source.attributedTextForTranslation())
    let spans = attributed.runs.compactMap { run in
      run.link.map { _ in String(attributed.characters[run.range]) }
    }

    #expect(source.appearance.fontWeight == .regular)
    #expect(spans == ["Apple Translation"])
  }

  @Test
  func linkWordsCoalesceAcrossUnderlineSamplingJitter() throws {
    let text = "Open the translation report, compare"
    let base = OverlaySourceAppearance(
      background: .black,
      foreground: .white,
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .medium
    )
    let blue = OverlayColor(red: 0.30, green: 0.57, blue: 1, alpha: 1)
    var firstWord = base
    firstWord.foreground = blue
    firstWord.fontWeight = .bold
    firstWord.isUnderlined = true
    var secondWord = firstWord
    secondWord.fontWeight = .semibold
    secondWord.isUnderlined = false
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.08),
      text: text,
      appearance: base,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "translation", in: text),
          box: CGRect(x: 0.28, y: 0.2, width: 0.24, height: 0.08),
          appearance: firstWord
        ),
        OverlaySourceStyleRun(
          range: try range(of: "report", in: text),
          box: CGRect(x: 0.53, y: 0.2, width: 0.14, height: 0.08),
          appearance: secondWord
        ),
      ]
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "en-US")
    )
    let attributed = try #require(source.attributedTextForTranslation())
    let linkedRuns = attributed.runs.filter { $0.link != nil }
    let linked = try #require(linkedRuns.first)
    let link = try #require(linked.link)

    #expect(linkedRuns.count == 1)
    #expect(String(attributed.characters[linked.range]) == "translation report")

    let alignment = TranslationStyleMapper.align(
      source: attributed,
      target: "번역 보고서를 열고 비교합니다.",
      alternatives: [link: "번역 보고서"]
    )
    let targetRuns = alignment.target.runs.filter { $0.link != nil }
    let targetRun = try #require(targetRuns.first)
    #expect(targetRuns.count == 1)
    #expect(String(alignment.target.characters[targetRun.range]) == "번역 보고서")
  }

  @Test
  func styleMapperUsesShortTranslatedAlternativeWhenLiteralChanges() throws {
    var source = AttributedString("rameshsunkara opened this issue")
    let link = URL(string: "swiftycrow-style://run/0")!
    let range = try #require(source.range(of: "rameshsunkara"))
    source[range].link = link

    let alignment = TranslationStyleMapper.align(
      source: source,
      target: "라마쉬순카라가 이 이슈를 열었습니다.",
      alternatives: [link: "라마쉬순카라"]
    )

    #expect(alignment.unmatched.isEmpty)
    #expect(alignment.target.runs.compactMap(\.link) == [link])
  }

  @Test
  func coloredEnclosingPunctuationKeepsItsForeground() throws {
    let sourceText = "（旧石器）"
    let base = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .semibold
    )
    let orange = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.86, green: 0.42, blue: 0.25, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular
    )
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.08),
      text: sourceText,
      appearance: base,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "（", in: sourceText),
          box: CGRect(x: 0.2, y: 0.1, width: 0.04, height: 0.08),
          appearance: orange
        ),
        OverlaySourceStyleRun(
          range: try range(of: "）", in: sourceText),
          box: CGRect(x: 0.76, y: 0.1, width: 0.04, height: 0.08),
          appearance: orange
        ),
      ]
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "ja-JP")
    )
    let attributed = try #require(source.attributedTextForTranslation())
    let alignment = TranslationStyleMapper.align(source: attributed, target: "(구석기)")

    #expect(attributed.runs.compactMap(\.link).count == 2)
    #expect(alignment.unmatched.isEmpty)
    #expect(alignment.target.runs.compactMap(\.link).count == 2)
  }

  @Test
  func oneRecognizedBracketMirrorsItsStyleToTheTranslatedPair() throws {
    let sourceText = "旧石器）"
    let orange = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.86, green: 0.42, blue: 0.25, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular
    )
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.08),
      text: sourceText,
      appearance: OverlaySourceAppearance(
        background: .white,
        foreground: .black,
        confidence: 1,
        foregroundConfidence: 1,
        fontWeight: .semibold
      ),
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "）", in: sourceText),
          box: CGRect(x: 0.76, y: 0.1, width: 0.04, height: 0.08),
          appearance: orange
        )
      ]
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja-JP")
      ),
      initialContent: .pending
    )
    let source = try #require(line.source.attributedTextForTranslation())
    let alignment = TranslationStyleMapper.align(source: source, target: "(구석기)")
    line.showTranslation(
      "(구석기)",
      attributedText: alignment.target,
      language: Locale.Language(identifier: "ko-KR")
    )

    #expect(line.displayedStyleRuns.count == 2)
    #expect(line.displayedStyleRuns.allSatisfy { $0.appearance.foreground == orange.foreground })
  }

  @Test
  func monospacedCodeOnlyLineKeepsOriginalPixels() {
    var appearance = OverlaySourceAppearance.fallback
    appearance.fontDesign = .monospaced
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.05),
      text: ".github/instructions/*.instructions.md",
      appearance: appearance
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "en-US")
    )
    var spacedRecognition = recognized
    spacedRecognition.text = ". github/instructions/*.instructions.md"
    let spaced = OverlayLine.Source(
      recognized: spacedRecognition,
      language: Locale.Language(identifier: "en-US")
    )

    #expect(source.isProtectedLiteral)
    #expect(spaced.isProtectedLiteral)
  }

  @Test
  func compactTableMetadataBesideCodeKeepsOriginalPixels() {
    var codeAppearance = OverlaySourceAppearance.fallback
    codeAppearance.fontDesign = .monospaced
    let label = source(text: "GitHub Copilot", box: CGRect(x: 0.05, y: 0.4, width: 0.15, height: 0.04))
    let code = source(
      text: ".github/instructions/*.instructions.md",
      box: CGRect(x: 0.25, y: 0.4, width: 0.35, height: 0.04),
      appearance: codeAppearance
    )
    let prose = source(
      text: "This explanatory sentence should still be translated for the reader.",
      box: CGRect(x: 0.05, y: 0.5, width: 0.7, height: 0.04)
    )
    let sources = [label, code, prose]

    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: sources))
    #expect(OverlayTranslationPolicy.preservesSource(at: 1, in: sources))
    #expect(!OverlayTranslationPolicy.preservesSource(at: 2, in: sources))
  }

  @Test
  func visualRepositoryMetadataKeepsOriginalPixels() {
    let language = source(
      text: "• Swift",
      box: CGRect(x: 0.05, y: 0.8, width: 0.08, height: 0.04)
    )
    let count = source(
      text: "& 572",
      box: CGRect(x: 0.14, y: 0.8, width: 0.05, height: 0.04)
    )
    let prose = source(
      text: "Chapter 2",
      box: CGRect(x: 0.05, y: 0.9, width: 0.1, height: 0.04)
    )
    let sources = [language, count, prose]

    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: sources))
    #expect(OverlayTranslationPolicy.preservesSource(at: 1, in: sources))
    #expect(!OverlayTranslationPolicy.preservesSource(at: 2, in: sources))
  }

  @Test(arguments: [
    ("• Keep each bullet on a readable line.", false),
    ("● All systems operational", false),
    ("• Swift", true),
    ("● Swift 94 11", true),
  ])
  func bulletPreservationDistinguishesProseFromCompactMetadata(
    _ text: String,
    expectedPreservation: Bool
  ) {
    let value = source(text: text, box: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.04))

    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: [value]) == expectedPreservation)
  }

  @Test
  func unmatchedStyleDoesNotReplaceThePlainTranslation() throws {
    var source = AttributedString("狼煙")
    try tag("狼煙", with: "swiftycrow-style://run/0", in: &source)

    let alignment = TranslationStyleMapper.align(
      source: source,
      target: "봉화입니다."
    )

    #expect(String(alignment.target.characters) == "봉화입니다.")
    #expect(alignment.unmatched.map(\.text) == ["狼煙"])
  }

  @Test
  func translationCannotTurnOneRecoveredLineBreakIntoABlankParagraph() {
    let normalized = TranslationTextStructure.matchingSourceBreaks(
      "두 개의 수표가 대기 중입니다.\n\n오렌지색 표면은 유지됩니다.",
      source: "Two checks are pending.\nThe orange surface remains visible."
    )

    #expect(normalized == "두 개의 수표가 대기 중입니다.\n오렌지색 표면은 유지됩니다.")
  }

  @Test
  func intentionalSourceParagraphSpacingIsRetained() {
    let normalized = TranslationTextStructure.matchingSourceBreaks(
      "첫 문단입니다.\n\n\n둘째 문단입니다.",
      source: "First paragraph.\n\nSecond paragraph."
    )

    #expect(normalized == "첫 문단입니다.\n\n둘째 문단입니다.")
  }

  // MARK: Private

  private func range(of substring: String, in text: String) throws -> NSRange {
    let range = (text as NSString).range(of: substring)
    return try #require(range.location != NSNotFound ? range : nil)
  }

  private func tag(
    _ substring: String,
    with link: String,
    in attributed: inout AttributedString
  ) throws {
    let range = try #require(attributed.range(of: substring))
    attributed[range].link = URL(string: link)
  }

  private func source(
    text: String,
    box: CGRect,
    appearance: OverlaySourceAppearance = .fallback
  ) -> OverlayLine.Source {
    OverlayLine.Source(
      recognized: OCRResult.Line(
        boundingBoxNormalized: box,
        text: text,
        appearance: appearance
      ),
      language: Locale.Language(identifier: "en-US")
    )
  }
}
