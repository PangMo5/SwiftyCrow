// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Core Text typesetting")
struct CoreTextTypesetterTests {

  // MARK: Internal

  struct VerticalCase: Sendable, CustomTestStringConvertible {
    let language: String
    let text: String

    var testDescription: String {
      language
    }
  }

  @Test
  func koreanVerticalColumnsKeepWordsTogetherAndStayCompact() throws {
    let text = "괜찮다면 지금 시작해요."
    let fontSize: CGFloat = 22.75
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: text,
      language: Locale.Language(identifier: "ko"),
      fontSize: fontSize,
      constrainedToHeight: 154
    )
    let columns = try substrings(plan.columns, in: text)

    #expect(columns == ["괜찮다면 지금 ", "시작해요."])
    #expect(plan.columnGap <= fontSize * 0.15)
    #expect(plan.requiredWidth < fontSize * 3)
  }

  @Test
  func koreanEmergencyBreakMovesWholeWordToNextColumn() throws {
    let text = "갑자기 찾아와서 미안해요."
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: text,
      language: Locale.Language(identifier: "ko"),
      fontSize: 29.44,
      constrainedToHeight: 342.8
    )
    let columns = try substrings(plan.columns, in: text)

    #expect(columns == ["갑자기 찾아와서 ", "미안해요."])
    #expect(CoreTextTypesetter.verticalColumnsPreserveWords(
      text: text,
      language: Locale.Language(identifier: "ko"),
      fontSize: 29.44,
      constrainedToHeight: 342.8
    ))
  }

  @Test(arguments: [
    VerticalCase(language: "ja", text: "2026年8月27日です。OKなら今すぐ始めよう。"),
    VerticalCase(language: "ko", text: "오늘 중요한 이야기가 있어요. 괜찮다면 지금 시작해요."),
    VerticalCase(language: "zh-Hans", text: "今天有重要的事情告诉你。如果可以的话，我们现在开始吧。"),
  ])
  func verticalPlansConsumeEveryComposedCharacter(_ testCase: VerticalCase) throws {
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: testCase.text,
      language: Locale.Language(identifier: testCase.language),
      fontSize: 24,
      constrainedToHeight: 180
    )
    let columns = try substrings(plan.columns, in: testCase.text)

    #expect(!columns.isEmpty)
    #expect(columns.joined() == testCase.text)
    #expect(plan.columns.reduce(0) { $0 + $1.length } == (testCase.text as NSString).length)
  }

  @Test
  func englishFontFitsTheLongestWordBeforeWrapping() {
    let language = Locale.Language(identifier: "en-US")
    let availableWidth: CGFloat = 62
    let fontSize = CoreTextTypesetter.horizontalWordFittedFontSize(
      text: "I have something important to tell you.",
      language: language,
      constrainedToWidth: availableWidth,
      preferred: 28,
      minimum: 6
    )
    let longestWord = CoreTextTypesetter.suggestedHorizontalSize(
      text: "something",
      language: language,
      fontSize: fontSize,
      constrainedToWidth: 1_000
    )

    #expect(fontSize < 28)
    #expect(longestWord.width <= availableWidth + 1)
    #expect(CoreTextTypesetter.horizontalWordsFit(
      text: "I have something important to tell you.",
      language: language,
      fontSize: fontSize,
      constrainedToWidth: availableWidth
    ))
  }

  @Test
  func horizontalLineHeightMultipleParticipatesInFitting() {
    let text = "첫 번째 줄과 두 번째 줄의 간격을 원본과 동일하게 유지합니다."
    let language = Locale.Language(identifier: "ko-KR")
    let size = CGSize(width: 180, height: 72)
    let defaultSize = CoreTextTypesetter.fittedFontSize(
      text: text,
      language: language,
      flow: .horizontal(.leftToRight),
      constrainedTo: size,
      preferred: 24,
      minimum: 6
    )
    let spacedSize = CoreTextTypesetter.fittedFontSize(
      text: text,
      language: language,
      flow: .horizontal(.leftToRight),
      constrainedTo: size,
      preferred: 24,
      minimum: 6,
      lineHeightMultiple: 1.35
    )

    #expect(spacedSize <= defaultSize)
    #expect(CoreTextTypesetter.fits(
      text: text,
      language: language,
      flow: .horizontal(.leftToRight),
      fontSize: spacedSize,
      in: size,
      lineHeightMultiple: 1.35
    ))
  }

  // MARK: Private

  private func substrings(_ ranges: [NSRange], in text: String) throws -> [String] {
    try ranges.map { range in
      String(text[try #require(Range(range, in: text))])
    }
  }
}
