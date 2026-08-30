// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

// MARK: - OverlayTextFlowTests

@Suite("Overlay text flow")
struct OverlayTextFlowTests {

  // MARK: Internal

  struct TranslationCase: Sendable, CustomTestStringConvertible {
    let name: String
    let sourceIsVertical: Bool
    let target: String
    let text: String
    let expected: OverlayTextFlow

    var testDescription: String {
      name
    }
  }

  struct WrittenLanguageCase: Sendable, CustomTestStringConvertible {
    let lhs: String
    let rhs: String
    let expected: Bool

    var testDescription: String {
      "\(lhs) and \(rhs)"
    }
  }

  @Test(arguments: [
    TranslationCase(
      name: "vertical Japanese to English",
      sourceIsVertical: true,
      target: "en-US",
      text: "I have something important to tell you today.",
      expected: .horizontal(.leftToRight)
    ),
    TranslationCase(
      name: "vertical Japanese to Arabic",
      sourceIsVertical: true,
      target: "ar",
      text: "لدي شيء مهم لأخبرك به",
      expected: .horizontal(.rightToLeft)
    ),
    TranslationCase(
      name: "vertical Japanese to Hebrew",
      sourceIsVertical: true,
      target: "he",
      text: "יש לי משהו חשוב לומר לך",
      expected: .horizontal(.rightToLeft)
    ),
    TranslationCase(
      name: "vertical Japanese stays vertical",
      sourceIsVertical: true,
      target: "ja",
      text: "今日は大切な話があります",
      expected: .vertical(.rightToLeft)
    ),
    TranslationCase(
      name: "vertical Simplified Chinese stays vertical",
      sourceIsVertical: true,
      target: "zh-Hans",
      text: "今天有重要的事情告诉你",
      expected: .vertical(.rightToLeft)
    ),
    TranslationCase(
      name: "vertical Korean stays vertical",
      sourceIsVertical: true,
      target: "ko",
      text: "오늘 중요한 이야기가 있어요",
      expected: .vertical(.rightToLeft)
    ),
    TranslationCase(
      name: "CJK dominant mixed script stays vertical",
      sourceIsVertical: true,
      target: "ja",
      text: "OKなら今すぐ始めよう",
      expected: .vertical(.rightToLeft)
    ),
    TranslationCase(
      name: "Latin dominant mixed script becomes horizontal",
      sourceIsVertical: true,
      target: "en-US",
      text: "Meet ゆきえ at the station",
      expected: .horizontal(.leftToRight)
    ),
    TranslationCase(
      name: "mixed script tie follows English target",
      sourceIsVertical: true,
      target: "en-US",
      text: "AB世界",
      expected: .horizontal(.leftToRight)
    ),
    TranslationCase(
      name: "mixed script tie follows Japanese target",
      sourceIsVertical: true,
      target: "ja",
      text: "AB世界",
      expected: .vertical(.rightToLeft)
    ),
    TranslationCase(
      name: "actual Japanese output overrides English metadata",
      sourceIsVertical: true,
      target: "en-US",
      text: "今日は晴れです",
      expected: .vertical(.rightToLeft)
    ),
    TranslationCase(
      name: "actual Latin output overrides Japanese metadata",
      sourceIsVertical: true,
      target: "ja",
      text: "SwiftyCrow",
      expected: .horizontal(.leftToRight)
    ),
    TranslationCase(
      name: "Japanese punctuation falls back to target script",
      sourceIsVertical: true,
      target: "ja",
      text: "！？……",
      expected: .vertical(.rightToLeft)
    ),
    TranslationCase(
      name: "Japanese digits fall back to target script",
      sourceIsVertical: true,
      target: "ja",
      text: "2026",
      expected: .vertical(.rightToLeft)
    ),
    TranslationCase(
      name: "English digits fall back to target script",
      sourceIsVertical: true,
      target: "en-US",
      text: "2026",
      expected: .horizontal(.leftToRight)
    ),
    TranslationCase(
      name: "Mongolian columns advance left to right",
      sourceIsVertical: true,
      target: "mn-Mong",
      text: "ᠮᠣᠩᠭᠣᠯ",
      expected: .vertical(.leftToRight)
    ),
    TranslationCase(
      name: "horizontal Japanese source remains horizontal",
      sourceIsVertical: false,
      target: "ja",
      text: "今日は晴れです",
      expected: .horizontal(.leftToRight)
    ),
  ])
  func resolvesFromDisplayedString(_ testCase: TranslationCase) {
    var line = makeLine(vertical: testCase.sourceIsVertical, initialContent: .pending)
    line.showTranslation(
      testCase.text,
      language: Locale.Language(identifier: testCase.target)
    )
    #expect(line.textFlow == testCase.expected)
    #expect(line.displayedText == testCase.text)
  }

  @Test
  func pendingAndUnavailableContentPreserveSourceFlow() {
    var line = makeLine(vertical: true, initialContent: .pending)
    #expect(line.textFlow == .vertical(.rightToLeft))
    #expect(line.displayedText == line.source.text)
    #expect(line.isPending)

    line.showUnavailable()
    #expect(line.textFlow == .vertical(.rightToLeft))
    #expect(line.displayedText == line.source.text)
    #expect(line.isUnavailable)
  }

  @Test
  func completedTranslationDoesNotLeakIntoFreshLiveTick() {
    let id = UUID(0)
    var previous = makeLine(id: id, vertical: true, initialContent: .pending)
    previous.showTranslation("Previous result", language: Locale.Language(identifier: "en-US"))

    let next = makeLine(id: previous.id, vertical: true, initialContent: .pending)
    #expect(next.id == previous.id)
    #expect(next.translatedText == nil)
    #expect(next.isPending)
    #expect(next.textFlow == .vertical(.rightToLeft))
  }

  @Test
  func blankTranslationBecomesExplicitFallback() {
    var line = makeLine(vertical: true, initialContent: .pending)
    line.showTranslation("  \n", language: Locale.Language(identifier: "en-US"))
    #expect(line.isUnavailable)
    #expect(line.displayedText == line.source.text)
  }

  @Test
  func systemHorizontalTextPreferenceOverridesVerticalCapableTranslation() {
    var line = makeLine(vertical: true, initialContent: .pending)
    line.showTranslation("今日は晴れです", language: Locale.Language(identifier: "ja"))
    #expect(line.textFlow == .vertical(.rightToLeft))
    #expect(line.textFlow(prefersHorizontalTextLayout: true) == .horizontal(.leftToRight))
  }

  @Test(arguments: [
    WrittenLanguageCase(lhs: "en-US", rhs: "en-GB", expected: true),
    WrittenLanguageCase(lhs: "ja", rhs: "ja-JP", expected: true),
    WrittenLanguageCase(lhs: "zh-Hans", rhs: "zh-Hant", expected: false),
    WrittenLanguageCase(lhs: "sr-Cyrl", rhs: "sr-Latn", expected: false),
    WrittenLanguageCase(lhs: "ko", rhs: "ja", expected: false),
  ])
  func comparesLanguageAndScriptButIgnoresRegion(_ testCase: WrittenLanguageCase) {
    let lhs = Locale.Language(identifier: testCase.lhs)
    let rhs = Locale.Language(identifier: testCase.rhs)
    #expect(lhs.usesSameWritingSystem(as: rhs) == testCase.expected)
  }

  @Test
  func findsOnlyShortTateChuYokoRuns() throws {
    let text = "2026年8月27日 OK ABCDE"
    let substrings = try CoreTextTypesetter.horizontalInVerticalRanges(in: text).map { range in
      let swiftRange = try #require(Range(range, in: text))
      return String(text[swiftRange])
    }
    #expect(substrings == ["2026", "8", "27", "OK"])
  }

  // MARK: Private

  private func makeLine(
    id: UUID = UUID(0),
    vertical: Bool,
    initialContent: OverlayLine.InitialContent
  ) -> OverlayLine {
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.4, y: 0.2, width: vertical ? 0.08 : 0.4, height: 0.3),
      text: "今日は大切な話があります",
      rowCount: vertical ? 2 : 1,
      isVerticalBlock: vertical,
      verticalCharScale: vertical ? 0.035 : 0
    )
    return OverlayLine(
      id: id,
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja")
      ),
      initialContent: initialContent
    )
  }
}

extension UUID {
  fileprivate init(_ value: UInt8) {
    self.init(uuid: (
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      value
    ))
  }
}
