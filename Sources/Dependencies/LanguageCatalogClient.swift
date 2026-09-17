// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import DependenciesMacros
import Translation

// MARK: - LanguageCatalogClient

/// Supported translation/OCR languages and installed model availability. Wrapping the
/// Translation · Vision availability query keeps it controllable in reducers.
@DependencyClient
struct LanguageCatalogClient {
  /// Supported languages. When `intersectedWithOCR` is true, narrows to ones
  /// Vision can also recognize — appropriate for source pickers.
  var supported: @Sendable (_ intersectedWithOCR: Bool) async -> [Language] = { _ in [] }
  var readiness: @Sendable (_ source: Language, _ target: Language, _ strategy: TranslationStrategy) async
    -> LanguageReadiness = { _, _, _ in .unchecked }

}

// MARK: DependencyKey

extension LanguageCatalogClient: DependencyKey {
  static let liveValue = LanguageCatalogClient(
    supported: { intersectedWithOCR in
      await Language.systemSupported(intersectedWithOCR: intersectedWithOCR)
    },
    readiness: { source, target, strategy in
      guard !source.isAuto, !target.isAuto else { return .unchecked }
      if source.localeLanguage.usesSameWritingSystem(as: target.localeLanguage) { return .sameLanguage }
      if #available(macOS 26.4, *) {
        let status = await LanguageAvailability(preferredStrategy: strategy.sessionStrategy)
          .status(from: source.localeLanguage, to: target.localeLanguage)
        if status == .installed { return .installed }
        guard !Task.isCancelled else { return .unchecked }
        let alternative: TranslationStrategy = strategy == .lowLatency ? .highFidelity : .lowLatency
        let other = await LanguageAvailability(preferredStrategy: alternative.sessionStrategy)
          .status(from: source.localeLanguage, to: target.localeLanguage)
        return LanguageReadiness.resolve(preferred: status, alternative: other)
      }
      let status = await LanguageAvailability().status(from: source.localeLanguage, to: target.localeLanguage)
      switch status {
      case .installed: return .installed
      case .supported: return .downloadRequired
      case .unsupported: return .unsupported
      @unknown default: return .unchecked
      }
    }
  )
}

extension DependencyValues {
  var languageCatalog: LanguageCatalogClient {
    get { self[LanguageCatalogClient.self] }
    set { self[LanguageCatalogClient.self] = newValue }
  }
}

// MARK: - LanguageReadiness

/// Preparation for one explicit language pair, never a claim about every auto-detected source.
enum LanguageReadiness: Equatable, Sendable {
  case unchecked
  case checking
  case installed
  case alternativeInstalled
  case preferredUnsupported
  case alternativeDownloadRequired
  case downloadRequired
  case unsupported
  case sameLanguage

  // MARK: Internal

  var needsLanguageDownload: Bool {
    switch self {
    case .downloadRequired,
         .alternativeInstalled,
         .alternativeDownloadRequired: true
    default: false
    }
  }

  /// An installed fallback is usable but is not readiness of the selected mode.
  static func resolve(preferred: LanguageAvailability.Status, alternative: LanguageAvailability.Status) -> Self {
    switch (preferred, alternative) {
    case (.installed, _): .installed
    case (.supported, .installed): .alternativeInstalled
    case (.unsupported, .installed): .preferredUnsupported
    case (.unsupported, .supported): .alternativeDownloadRequired
    case (.supported, .supported),
         (.supported, .unsupported): .downloadRequired
    case (.unsupported, .unsupported): .unsupported
    default: .unchecked
    }
  }

}
