// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct MultilingualParagraphLanguageTests {
  @Test
  func neighboringDocumentsCannotChangeAnAmbiguousLabelsLanguage() {
    let client = LanguageDetectionClient(detect: { text, _ in
      if text == "e" { return nil }
      return Language(code: text.contains("English") ? "en" : "ja")
    })
    let japanese = [
      OCRResult.Line(boundingBoxNormalized: .zero, text: "日本語の文章です", recognitionLanguages: ["ja"], recognitionContextID: 0),
      OCRResult.Line(boundingBoxNormalized: .zero, text: "e", recognitionLanguages: ["ja"], recognitionContextID: 0),
    ]
    let english = OCRResult.Line(
      boundingBoxNormalized: .zero,
      text: "English prose belongs to a separate source document.",
      recognitionLanguages: ["en"],
      recognitionContextID: 1
    )
    let standalone = client.resolveRecognizedSources(for: japanese, configured: .auto)
    let combined = client.resolveRecognizedSources(for: japanese + [english], configured: .auto)
    #expect(Array(combined.prefix(2)) == standalone)
    #expect(combined.map(\.code) == ["ja", "ja", "en"])
    #expect(client.resolveRecognizedSources(for: japanese + [english], configured: .init(code: "fr"))
      .allSatisfy { $0.code == "fr" })
  }

  @Test
  func nativeLanguageEvidenceOverridesAnAmbiguousShortTextGuess() {
    let client = LanguageDetectionClient(detect: { _, _ in Language(code: "hr") })
    let line = OCRResult.Line(boundingBoxNormalized: .zero, text: "QG", recognitionLanguages: ["en"])
    #expect(client.resolveRecognizedSources(for: [line], configured: .auto).first?.code == "en")
    #expect(client.resolveRecognizedSources(for: [line], configured: Language(code: "fr")).first?.code == "fr")
    let mixed = OCRResult.Line(boundingBoxNormalized: .zero, text: "文 A", recognitionLanguages: ["ja"])
    #expect(client.resolveRecognizedSources(for: [mixed], configured: .auto).first?.code == "ja")
  }

  @Test(arguments: ["th", "ja", "ar"])
  func nativeLanguageMustAgreeWithTheObservedScript(_ hint: String) {
    let client = LanguageDetectionClient(detect: { _, _ in Language(code: "en") })
    let line = OCRResult.Line(boundingBoxNormalized: .zero, text: "size", recognitionLanguages: [hint])
    #expect(client.resolveRecognizedSources(for: [line], configured: .auto).first?.code == "en")
  }

  @Test
  func hanHeadwordUsesJapanesePronunciationContextInsteadOfEnglishPageLanguage() {
    let texts = [
      "相槌",
      "The following entry describes a Japanese noun. Read the examples and pronunciation below.",
      "あいづち",
      "JA 6 languages v",
    ]
    let sources = LanguageDetectionClient.liveValue.resolveSources(for: texts, configured: .auto)
    #expect(sources[0].localeLanguage.languageCode?.identifier == "ja")
    #expect(sources[1].localeLanguage.languageCode?.identifier == "en")
    #expect(sources[2].localeLanguage.languageCode?.identifier == "ja")
    #expect(sources[3].localeLanguage.languageCode?.identifier == "en")
  }

  @Test
  func embeddedFrenchAndKoreanQuotesDoNotTurnEnglishProseIntoFrench() {
    let text = """
      The low-latency model still translates Le prix est passé de 50 dollars à 15 dollars. \
      as 가격이 $50에서 $15로 상승했습니다.. This reverses the direction implied by the numbers. \
      The error reproduces with the Translation API directly, without OCR or rendering. \
      Page context and spelling out the numbers did not resolve it. Adding decimal notation \
      changed the answer, but that is not a reliable semantic correction and was not added to production.
      """
    #expect(LanguageDetectionClient.liveValue.detect(text, 0.65)?.localeLanguage.languageCode?.identifier == "en")
    let languages = LanguageDetectionClient.liveValue.resolveSources(for: [text], configured: .auto)
    #expect(languages.first?.localeLanguage.languageCode?.identifier == "en")
  }

  @Test(arguments: [
    (
      "de",
      "Bewahren Sie die Originaldateien auf. Überprüfen Sie alle Änderungen, bevor Sie fortfahren. Die Schaltfläche trägt die Aufschrift Download now. Trennen Sie das Gerät während der Aktualisierung nicht vom Computer."
    ),
    ("ko", "원본 파일을 보관하세요. 변경 사항을 확인한 다음 계속 진행하세요. 버튼에는 Download now라고 적혀 있어요. 업데이트가 진행되는 동안 기기를 분리하지 마세요."),
    (
      "fr",
      "Conservez les fichiers originaux. Vérifiez les modifications avant de continuer. Le bouton indique Download now. Ne déconnectez pas votre appareil pendant la mise à jour."
    ),
  ])
  func pageLanguageIsNotAssumedToBeEnglish(_ sample: (String, String)) {
    #expect(LanguageDetectionClient.liveValue.detect(sample.1, 0.65)?.localeLanguage.languageCode?.identifier == sample.0)
  }
}
