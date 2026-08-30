// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Japanese ruby OCR correction")
struct JapaneseRubyOCRCorrectorTests {

  @Test
  func acceptsConfidentBaseGlyphCorrection() {
    let corrected = JapaneseRubyOCRCorrector.preferredCorrection(
      original: "腸や驚をとるための「やり」と",
      candidate: "動物や魚をとるための「やり」と",
      confidence: 1
    )

    #expect(corrected == "動物や魚をとるための「やり」と")
  }

  @Test
  func rejectsCandidateThatOnlyDropsAValidGlyph() {
    let corrected = JapaneseRubyOCRCorrector.preferredCorrection(
      original: "ナイフ型石器",
      candidate: "ナイフ石器",
      confidence: 0.5
    )

    #expect(corrected == nil)
  }

  @Test
  func acceptsCompactHanCorrectionDespiteSevereInitialOCRDamage() {
    let corrected = JapaneseRubyOCRCorrector.preferredCorrection(
      original: "貓岩-",
      candidate: "細石器",
      confidence: 0.3
    )

    #expect(corrected == "細石器")
  }

  @Test
  func rejectsLowConfidenceCroppedHeading() {
    let corrected = JapaneseRubyOCRCorrector.preferredCorrection(
      original: "おの型石器",
      candidate: "おの坐白各",
      confidence: 0.3
    )

    #expect(corrected == nil)
  }

  @Test
  func rejectsKanaOnlyFuriganaMutation() {
    let corrected = JapaneseRubyOCRCorrector.preferredCorrection(
      original: "さいせっ",
      candidate: "さいせつ",
      confidence: 0.5
    )

    #expect(corrected == nil)
  }

  @Test
  func preservesReliableOriginalKanaWhileCorrectingKanji() {
    let corrected = JapaneseRubyOCRCorrector.preferredCorrection(
      original: "手でにぎったり、柔",
      candidate: "手でにぎうたり、木",
      confidence: 0.5
    )

    #expect(corrected == "手でにぎったり、木")
  }

  @Test
  func remapsUnchangedPunctuationStyleAfterTextCorrection() {
    let original = "脂岩器時花の道真＝折製若器）"
    let corrected = "旧石器時代の道具＝打製石器）"
    let closingRange = (original as NSString).range(of: "）")
    let run = OverlaySourceStyleRun(
      range: closingRange,
      box: .zero,
      appearance: .fallback
    )

    let remapped = JapaneseRubyOCRCorrector.remappedStyleRuns(
      [run],
      from: original,
      to: corrected
    )

    #expect(remapped.count == 1)
    #expect((corrected as NSString).substring(with: remapped[0].range) == "）")
  }
}
