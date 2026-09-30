// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import FoundationModels
import Translation

/// Validates the user's selected strategy. Never substitutes another engine.
enum TranslationModelResolver {

  // MARK: Internal

  struct ModelError: LocalizedError {
    var message: String

    var errorDescription: String? {
      message
    }
  }

  static func validateSelection(source: Locale.Language, target: Locale.Language, strategy: TranslationStrategy) async throws {
    // A low-latency installed-only session reports missing assets itself and
    // never upgrades to Apple Intelligence. Availability metadata can lag asset
    // readiness after launch, so it must not veto the actual session.
    // Both the session AND LanguageAvailability can fall back to traditional
    // models. Check Apple Intelligence separately before trusting pair status.
    guard strategy == .highFidelity else { return }
    guard #available(macOS 26.4, *) else {
      throw modelError(source: source, target: target, unsupported: true)
    }
    try validateAppleIntelligence(SystemLanguageModel.default.availability)
    let status = await LanguageAvailability(preferredStrategy: strategy.sessionStrategy).status(from: source, to: target)
    try Task.checkCancellation()
    if status == .installed { return }
    throw modelError(source: source, target: target, unsupported: status == .unsupported)
  }

  static func validateAppleIntelligence(_ availability: SystemLanguageModel.Availability) throws {
    switch availability {
    case .available:
      return

    case .unavailable(let reason):
      let message =
        switch reason {
        case .deviceNotEligible:
          String(localized: "This device does not support Apple Intelligence. Select Low latency for translation.")
        case .appleIntelligenceNotEnabled:
          String(localized: "Enable Apple Intelligence in System Settings to use High fidelity translation.")
        case .modelNotReady:
          String(localized: "Apple Intelligence is preparing its model. Try High fidelity translation again when it is ready.")
        @unknown default:
          String(localized: "High fidelity translation is unavailable because Apple Intelligence is not ready.")
        }
      throw ModelError(message: message)

    @unknown default:
      throw ModelError(
        message: String(localized: "High fidelity translation is unavailable because Apple Intelligence is not ready.")
      )
    }
  }

  static func explaining(_ error: any Error, source: Locale.Language, target: Locale.Language) -> any Error {
    if TranslationError.notInstalled ~= error { return modelError(source: source, target: target, unsupported: false) }
    if
      TranslationError.unsupportedSourceLanguage ~= error || TranslationError.unsupportedTargetLanguage ~= error
      || TranslationError.unsupportedLanguagePairing ~= error
    { return modelError(
      source: source,
      target: target,
      unsupported: true
    ) }
    return error
  }

  // MARK: Private

  private static func modelError(source: Locale.Language, target: Locale.Language, unsupported: Bool) -> ModelError {
    let sourceName = Locale.current
      .localizedString(forLanguageCode: source.languageCode?.identifier ?? source.maximalIdentifier) ?? source.maximalIdentifier
    let targetName = Locale.current
      .localizedString(forLanguageCode: target.languageCode?.identifier ?? target.maximalIdentifier) ?? target.maximalIdentifier
    return ModelError(message: unsupported
      ? String(localized: "The selected translation mode does not support \(sourceName) → \(targetName).")
      :
      String(
        localized: "The selected translation mode has no installed model for \(sourceName) → \(targetName). Download these languages in System Settings."
      ))
  }
}
