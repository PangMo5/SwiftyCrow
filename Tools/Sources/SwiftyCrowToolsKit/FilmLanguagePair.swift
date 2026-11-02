// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A localized product demo must produce the language of the page, not merely
/// localize the surrounding controls and editorial captions.
struct FilmLanguagePair {

  // MARK: Lifecycle

  init(film: JSON, locale: String) throws {
    let pair = film["languagePairs"][locale]
    source = pair["sourceLanguage"].str
    target = pair["translationLanguage"].str
    try require(!source.isEmpty && !target.isEmpty, "Missing demo language pair for \(locale)")
    try require(
      Self.writingSystem(target) == Self.writingSystem(locale),
      "Demo output language must match its page: \(target) / \(locale)",
    )
    try require(
      Self.writingSystem(source) != Self.writingSystem(target),
      "Demo source and translated output must use different written languages",
    )
  }

  // MARK: Internal

  let source: String
  let target: String

  // MARK: Private

  private static func writingSystem(_ code: String) -> String {
    let language = Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier)
    return "\(language.languageCode?.identifier ?? "")-\(language.script?.identifier ?? "")"
  }

}
