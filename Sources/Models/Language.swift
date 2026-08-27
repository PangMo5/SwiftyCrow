// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Translation
import Vision

// MARK: - Language

struct Language: Codable, Equatable, Hashable, Identifiable, Sendable {
  let code: String

  var id: String {
    code
  }

  var displayName: String {
    if isAuto { return "Auto (detect)" }
    return Locale.current.localizedString(forIdentifier: code) ?? code
  }

  /// Whether this is the "detect the source language automatically" sentinel.
  var isAuto: Bool {
    code == Language.autoCode
  }

  var localeLanguage: Locale.Language {
    Locale.Language(identifier: code)
  }
}

extension Locale.Language {
  /// Whether text in this language is conventionally set in vertical columns.
  /// Vertical CJK column layout only reads correctly when the text itself is
  /// CJK — a Latin translation stacked one character per row is unreadable.
  var usesVerticalScript: Bool {
    switch languageCode?.identifier {
    case "ja",
         "zh",
         "ko",
         "yue": true
    default: false
    }
  }
}

extension Language {
  /// Reserved code for the auto-detect source sentinel.
  static let autoCode = "auto"

  /// "Detect the source language automatically" — OCR detects the recognition
  /// language and the text's dominant language drives translation.
  static let auto = Language(code: autoCode)

  /// Default source language for new installs (most screen text users
  /// translate is English).
  static let defaultSource = Language(code: "en-US")

  /// Default for new installs. Picks the user's most-preferred system
  /// language; falls back to whatever Translation reports first if Locale
  /// somehow returns nothing useful.
  static func systemPreferred() -> Language {
    let preferred = Locale.preferredLanguages.first
      ?? Locale.current.language.maximalIdentifier
    return Language(code: preferred)
  }

  /// Languages reported by Apple Translation as supported on this device.
  /// When `intersectedWithOCR` is true, narrows the list to ones Vision can
  /// also OCR — appropriate for source pickers.
  static func systemSupported(intersectedWithOCR: Bool) async -> [Language] {
    let translationLangs = await LanguageAvailability().supportedLanguages
    var ids = Set(translationLangs.map(\.maximalIdentifier))
    if intersectedWithOCR {
      let request = RecognizeTextRequest()
      if let ocr = try? request.supportedRecognitionLanguages {
        ids.formIntersection(ocr.map(\.maximalIdentifier))
      }
    }
    return ids
      .filter { !$0.isEmpty }
      .map { Language(code: $0) }
      .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
  }
}
