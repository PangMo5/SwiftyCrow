// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Testing
@testable import SwiftyCrowToolsKit

@Suite("Demo output follows the page language")
struct FilmLanguagePairTests {

  // MARK: Internal

  @Test(arguments: ["en", "ja", "zh-Hans", "zh-Hant"])
  func `rejects korean output behind localized UI`(_ locale: String) {
    #expect(throws: ToolError.self) {
      try FilmLanguagePair(film: film(locale: locale, source: "en-US", target: "ko-KR"), locale: locale)
    }
  }

  @Test
  func `distinguishes chinese scripts`() throws {
    #expect(throws: ToolError.self) {
      try FilmLanguagePair(film: film(locale: "zh-Hant", source: "en-US", target: "zh-CN"), locale: "zh-Hant")
    }
    let pair = try FilmLanguagePair(film: film(locale: "zh-Hant", source: "en-US", target: "zh-TW"), locale: "zh-Hant")
    #expect(pair.target == "zh-TW")
  }

  @Test
  func `accepts regional alias but rejects untranslated source`() throws {
    _ = try FilmLanguagePair(film: film(locale: "en", source: "ko-KR", target: "en-GB"), locale: "en")
    #expect(throws: ToolError.self) {
      try FilmLanguagePair(film: film(locale: "ja", source: "ja-JP", target: "ja-JP"), locale: "ja")
    }
  }

  // MARK: Private

  private func film(locale: String, source: String, target: String) -> JSON {
    .object([("languagePairs", .object([(locale, .object([
      ("sourceLanguage", .string(source)),
      ("translationLanguage", .string(target)),
    ]))]))])
  }

}
