// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Japanese ruby OCR correction")
struct JapaneseRubyOCRCorrectorTests {
  @Test(arguments: [0.0, -0.00000001, -0.002])
  func touchingColumnsDoNotAddExtraRubyMargin(_ overlap: Double) {
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3, y: 0.1, width: 0.04, height: 0.08),
      text: "旧A",
      isVerticalBlock: true,
      verticalCharScale: 0.035
    )
    let neighbor = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.34 + overlap, y: 0.1, width: 0.03, height: 0.2),
      text: "となり",
      isVerticalBlock: true,
      verticalCharScale: 0.03
    )
    var further = neighbor
    further.boundingBoxNormalized.origin.x = 0.4
    let crop = JapaneseRubyOCRCorrector.verticalCorrectionCrop(
      for: source,
      among: [source, neighbor, further],
      imageSize: CGSize(width: 1000, height: 1000)
    )
    #expect(crop.minX == 298)
    #expect(crop.maxX <= ceil(source.boundingBoxNormalized.maxX * 1000) + 2)
    #expect(crop.width < 46)
    var noisy = source
    noisy.boundingBoxNormalized.origin.x -= 1e-9
    noisy.boundingBoxNormalized.origin.y -= 1e-9
    #expect(JapaneseRubyOCRCorrector.verticalCorrectionCrop(
      for: noisy,
      among: [noisy, neighbor, further],
      imageSize: CGSize(width: 1000, height: 1000)
    ) == crop)
  }

  @Test
  func longColumnsKeepTheirCompleteOuterContext() {
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.299999999, y: 0.099999999, width: 0.04, height: 0.4),
      text: "長い文章をそのまま読む",
      isVerticalBlock: true,
      verticalCharScale: 0.03
    )
    let crop = JapaneseRubyOCRCorrector.verticalCorrectionCrop(
      for: source,
      among: [source],
      imageSize: CGSize(width: 1000, height: 1000)
    )
    #expect(crop.minX <= source.boundingBoxNormalized.minX * 1000 - 2)
    #expect(crop.minY <= source.boundingBoxNormalized.minY * 1000 - 2)
    #expect(crop.maxY >= source.boundingBoxNormalized.maxY * 1000 + 2)
  }

  @Test
  func anInvalidLongerHypothesisCannotHideAValidCompactCorrection() throws {
    let numeric = OCRResult.Line(boundingBoxNormalized: .zero, text: "123", recognitionConfidence: 0.5)
    let word = OCRResult.Line(boundingBoxNormalized: .zero, text: "新語", recognitionConfidence: 0.5)
    let result = try #require(JapaneseRubyOCRCorrector.preferredVerticalCorrection(original: "旧A", candidates: [numeric, word]))
    #expect(result.text == word.text)
    #expect(result.candidate == word)
  }

  @Test
  func correctedTranscriptRetainsItsAcceptedLanguageEvidenceAndSourceOwnership() {
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3, y: 0.1, width: 0.04, height: 0.08),
      text: "旧A",
      recognitionConfidence: 0.3,
      isVerticalBlock: true,
      verticalCharScale: 0.03,
      recognitionGroupID: 7,
      recognitionLanguages: ["zh"]
    )
    let candidate = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3, y: 0.1, width: 0.03, height: 0.08),
      text: "新語",
      recognitionConfidence: 0.5,
      recognitionLanguages: ["ja"]
    )
    let result = JapaneseRubyOCRCorrector.applyingVerticalCorrection((candidate, candidate.text), to: source)
    #expect(result.text == candidate.text)
    #expect(result.recognitionLanguages == ["ja"])
    #expect(result.recognitionConfidence == candidate.recognitionConfidence)
    #expect(result.boundingBoxNormalized == source.boundingBoxNormalized)
    #expect(result.recognitionGroupID == source.recognitionGroupID)
    #expect(result.isVerticalBlock)
    #expect(result.verticalCharScale == source.verticalCharScale)
    var strongerOldReading = source
    strongerOldReading.recognitionConfidence = 0.4
    var corroboratedReading = candidate
    corroboratedReading.recognitionConfidence = 0.3
    #expect(JapaneseRubyOCRCorrector.applyingVerticalCorrection(
      (corroboratedReading, corroboratedReading.text),
      to: strongerOldReading
    ).recognitionConfidence == corroboratedReading.recognitionConfidence)
  }

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
