import ComposableArchitecture
import DependenciesMacros
import Foundation
import Translation

// MARK: - TranslationClient

@DependencyClient
struct TranslationClient {
  var translate: @Sendable (
    _ text: String,
    _ source: Locale.Language,
    _ target: Locale.Language,
    _ strategy: TranslationStrategy
  ) async throws -> String
}

// MARK: DependencyKey

extension TranslationClient: DependencyKey {
  static let liveValue = TranslationClient(
    translate: { text, source, target, strategy in
      let session =
        if #available(macOS 26.4, *) {
          TranslationSession(installedSource: source, target: target, preferredStrategy: strategy.sessionStrategy)
        } else {
          TranslationSession(installedSource: source, target: target)
        }
      let response = try await session.translate(text)
      return response.targetText
    }
  )
}

extension DependencyValues {
  var translation: TranslationClient {
    get { self[TranslationClient.self] }
    set { self[TranslationClient.self] = newValue }
  }
}

@available(macOS 26.4, *)
extension TranslationStrategy {
  var sessionStrategy: TranslationSession.Strategy {
    switch self {
    case .lowLatency: .lowLatency
    case .highFidelity: .highFidelity
    }
  }
}
