// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
@testable import SwiftyCrow

@Suite("OCR text tokenization")
struct OCRTextTokenizationTests {
  @Test(arguments: ["सेटिंग गोपनीयता", "اَلْعَرَبِيَّة اللُّغَة", "cafe\u{301} re\u{301}sume\u{301}"])
  func combiningMarksRemainInsideTheirWords(_ text: String) {
    let tokens = OCRTextTokenization.ranges(in: text).map { String(text[$0]) }
    #expect(tokens == text.split(separator: " ").map(String.init))
  }

  @Test
  func separatesEnclosingPunctuationFromCJKTitle() {
    let text = "（旧石器時代の道具＝打製石器）"
    let tokens = OCRTextTokenization.ranges(in: text).map { String(text[$0]) }

    #expect(tokens == ["（", "旧石器時代の道具", "＝", "打製石器", "）"])
  }

  @Test
  func keepsLatinWordsAndTechnicalPunctuationIndependent() {
    let text = "Agent Skills #179"
    let tokens = OCRTextTokenization.ranges(in: text).map { String(text[$0]) }

    #expect(tokens == ["Agent", "Skills", "#", "179"])
  }
}
