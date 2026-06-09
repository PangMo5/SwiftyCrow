import ComposableArchitecture
import DependenciesMacros

// MARK: - LanguageCatalogClient

/// The translation/OCR languages installed on this device. Wrapping the
/// Translation · Vision availability query keeps it controllable in reducers.
@DependencyClient
struct LanguageCatalogClient {
  /// Supported languages. When `intersectedWithOCR` is true, narrows to ones
  /// Vision can also recognize — appropriate for source pickers.
  var supported: @Sendable (_ intersectedWithOCR: Bool) async -> [Language] = { _ in [] }
}

extension LanguageCatalogClient: DependencyKey {
  static let liveValue = LanguageCatalogClient(
    supported: { intersectedWithOCR in
      await Language.systemSupported(intersectedWithOCR: intersectedWithOCR)
    }
  )
}

extension DependencyValues {
  var languageCatalog: LanguageCatalogClient {
    get { self[LanguageCatalogClient.self] }
    set { self[LanguageCatalogClient.self] = newValue }
  }
}
