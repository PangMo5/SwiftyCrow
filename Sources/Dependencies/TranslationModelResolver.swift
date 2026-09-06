// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Translation

enum TranslationModelResolver {
  struct Selection: Sendable {
    var strategy: TranslationStrategy
    var notice: String?
  }

  struct ModelError: LocalizedError {
    var message: String

    var errorDescription: String? {
      message
    }
  }

  static func choose(
    preferred: TranslationStrategy,
    preferredInstalled: Bool,
    alternativeInstalled: Bool
  ) -> TranslationStrategy? {
    if preferredInstalled { return preferred }
    if alternativeInstalled { return preferred == .lowLatency ? .highFidelity : .lowLatency }
    return nil
  }

  static func resolve(
    source: Locale.Language,
    target: Locale.Language,
    preferred: TranslationStrategy
  ) async throws -> Selection {
    guard #available(macOS 26.4, *) else { return Selection(strategy: preferred) }
    let alternative: TranslationStrategy = preferred == .lowLatency ? .highFidelity : .lowLatency
    let requested = await LanguageAvailability(preferredStrategy: preferred.sessionStrategy).status(from: source, to: target)
    if requested == .installed { return Selection(strategy: preferred) }
    try Task.checkCancellation()
    let other = await LanguageAvailability(preferredStrategy: alternative.sessionStrategy).status(from: source, to: target)
    let sourceName = Locale.current
      .localizedString(forLanguageCode: source.languageCode?.identifier ?? source.maximalIdentifier) ?? source.maximalIdentifier
    let targetName = Locale.current
      .localizedString(forLanguageCode: target.languageCode?.identifier ?? target.maximalIdentifier) ?? target.maximalIdentifier
    guard
      let selected = choose(
        preferred: preferred,
        preferredInstalled: requested == .installed,
        alternativeInstalled: other == .installed
      )
    else {
      throw ModelError(message: requested == .unsupported && other == .unsupported
        ? "Translation is not supported from \(sourceName) to \(targetName)."
        : "No translation model is installed for \(sourceName) → \(targetName). Download these languages in System Settings.")
    }
    // This is resolved before submitting any work, not retried after an opaque
    // engine failure. Every response carries the choice so the UI explains it.
    return Selection(
      strategy: selected,
      notice: "Using \(selected.displayName) for \(sourceName) → \(targetName); the preferred model is not installed."
    )
  }

}
