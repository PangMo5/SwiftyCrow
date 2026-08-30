// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import NaturalLanguage

// MARK: - OverlayInlineDirection

enum OverlayInlineDirection: Equatable, Sendable {
  case leftToRight
  case rightToLeft
}

// MARK: - OverlayColumnProgression

enum OverlayColumnProgression: Equatable, Sendable {
  case rightToLeft
  case leftToRight
}

// MARK: - OverlayTextFlow

enum OverlayTextFlow: Equatable, Sendable {
  case horizontal(OverlayInlineDirection)
  case vertical(OverlayColumnProgression)
}

// MARK: - OverlayTextFlowResolver

/// Resolves the writing flow from the string that will actually be shown.
///
/// A locale tells us the normal inline direction and supplies a useful fallback
/// for strings made entirely from punctuation or digits. Natural Language adds
/// the missing piece for translated text: its dominant ISO 15924 script. That
/// keeps a Latin translation horizontal even when it replaces a vertical CJK
/// source, while a CJK translation can continue to use the source's columns.
enum OverlayTextFlowResolver {

  // MARK: Internal

  static func sourceFlow(language: Locale.Language, layout: OverlaySourceLayout) -> OverlayTextFlow {
    switch layout {
    case .horizontal:
      .horizontal(inlineDirection(for: language, dominantScript: nil))
    case .vertical(_, let progression):
      .vertical(progression)
    }
  }

  static func translatedFlow(
    text: String,
    language: Locale.Language,
    replacing sourceLayout: OverlaySourceLayout
  ) -> OverlayTextFlow {
    let evidence = scriptEvidence(in: text)
    guard case .vertical = sourceLayout else {
      return .horizontal(inlineDirection(for: language, dominantScript: evidence.dominantScript))
    }

    let useVertical: Bool =
      if evidence.verticalCharacterCount != evidence.horizontalCharacterCount {
        evidence.verticalCharacterCount > evidence.horizontalCharacterCount
      } else {
        isVerticalCapable(script: language.script?.identifier)
      }

    if useVertical {
      let script = evidence.dominantVerticalScript ?? language.script?.identifier
      return .vertical(columnProgression(for: language, script: script))
    }
    return .horizontal(inlineDirection(for: language, dominantScript: evidence.dominantScript))
  }

  static func horizontalFlow(text: String, language: Locale.Language) -> OverlayTextFlow {
    let script = scriptEvidence(in: text).dominantScript
    return .horizontal(inlineDirection(for: language, dominantScript: script))
  }

  static func columnProgression(for language: Locale.Language) -> OverlayColumnProgression {
    columnProgression(for: language, script: language.script?.identifier)
  }

  static func scriptEvidence(in text: String) -> ScriptEvidence {
    guard !text.isEmpty else { return ScriptEvidence() }

    let tagger = NLTagger(tagSchemes: [.script])
    tagger.string = text
    var counts = [String: Int]()
    tagger.enumerateTags(
      in: text.startIndex ..< text.endIndex,
      unit: .word,
      scheme: .script,
      options: [.omitWhitespace, .omitPunctuation]
    ) { tag, range in
      guard let script = tag?.rawValue, !commonScripts.contains(script) else { return true }
      let count = text[range].unicodeScalars.reduce(into: 0) { result, scalar in
        if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
          result += 1
        }
      }
      counts[script, default: 0] += count
      return true
    }

    return ScriptEvidence(counts: counts)
  }

  // MARK: Private

  private static let commonScripts: Set = ["Zinh", "Zyyy", "Zzzz"]
  private static let verticalScripts: Set = [
    "Bopo",
    "Hang",
    "Hani",
    "Hans",
    "Hant",
    "Hira",
    "Jpan",
    "Kana",
    "Kore",
    "Mong",
  ]

  private static func isVerticalCapable(script: String?) -> Bool {
    script.map(verticalScripts.contains) ?? false
  }

  private static func inlineDirection(
    for language: Locale.Language,
    dominantScript: String?
  ) -> OverlayInlineDirection {
    let directionalLanguage = dominantScript.map { script in
      let inferred = Locale.Language(identifier: "und-\(script)")
      return Locale.Language(identifier: inferred.maximalIdentifier)
    } ?? language
    return directionalLanguage.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
  }

  private static func columnProgression(
    for language: Locale.Language,
    script: String?
  ) -> OverlayColumnProgression {
    switch language.lineLayoutDirection {
    case .leftToRight:
      .leftToRight
    case .rightToLeft:
      .rightToLeft
    default:
      // Foundation reports the normal page layout for CJK and Mongolian
      // locales, not the optional vertical setting selected by Vision. In that
      // setting Mongolian advances left-to-right; CJK advances right-to-left.
      script == "Mong" ? .leftToRight : .rightToLeft
    }
  }
}

// MARK: - ScriptEvidence

struct ScriptEvidence: Equatable, Sendable {

  // MARK: Lifecycle

  init(counts: [String: Int] = [:]) {
    let meaningful = counts.filter { $0.value > 0 }
    self.counts = meaningful
    verticalCharacterCount = meaningful
      .filter { OverlayTextFlowResolver.isVerticalScript($0.key) }
      .values
      .reduce(0, +)
    horizontalCharacterCount = meaningful
      .filter { !OverlayTextFlowResolver.isVerticalScript($0.key) }
      .values
      .reduce(0, +)
  }

  // MARK: Internal

  let counts: [String: Int]
  let verticalCharacterCount: Int
  let horizontalCharacterCount: Int

  var dominantScript: String? {
    uniqueDominantScript(in: counts)
  }

  var dominantVerticalScript: String? {
    uniqueDominantScript(
      in: counts.filter { OverlayTextFlowResolver.isVerticalScript($0.key) }
    )
  }

  // MARK: Private

  private func uniqueDominantScript(in counts: [String: Int]) -> String? {
    guard let maximum = counts.values.max() else { return nil }
    let candidates = counts.filter { $0.value == maximum }.map(\.key)
    return candidates.count == 1 ? candidates[0] : nil
  }
}

extension OverlayTextFlowResolver {
  fileprivate static func isVerticalScript(_ script: String) -> Bool {
    verticalScripts.contains(script)
  }
}
