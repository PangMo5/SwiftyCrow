import ComposableArchitecture
import DependenciesMacros
import Foundation
import Translation

// MARK: - TranslationLine

/// A line to translate (or its translated result), tagged with the overlay
/// line's id so batch responses can be matched back as they stream in.
struct TranslationLine: Equatable, Sendable {
  var id: UUID
  var text: String
}

// MARK: - TranslationClient

@DependencyClient
struct TranslationClient {
  /// Translates all `lines` in a single `TranslationSession`, yielding each
  /// result as soon as it's ready (order isn't guaranteed; match by `id`).
  /// One session for the whole batch avoids per-line session setup.
  var translateBatch: @Sendable (
    _ lines: [TranslationLine],
    _ source: Locale.Language,
    _ target: Locale.Language,
    _ strategy: TranslationStrategy
  ) -> AsyncThrowingStream<TranslationLine, any Error> = { _, _, _, _ in
    AsyncThrowingStream { $0.finish() }
  }
}

// MARK: DependencyKey

extension TranslationClient: DependencyKey {
  static let liveValue = TranslationClient(
    translateBatch: { lines, source, target, strategy in
      AsyncThrowingStream { continuation in
        let pair = "\(source.maximalIdentifier)->\(target.maximalIdentifier)"
        let session =
          if #available(macOS 26.4, *) {
            TranslationSession(installedSource: source, target: target, preferredStrategy: strategy.sessionStrategy)
          } else {
            TranslationSession(installedSource: source, target: target)
          }
        let requests = lines.map {
          TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
        }
        let task = Task {
          do {
            for try await response in session.translate(batch: requests) {
              guard let id = response.clientIdentifier.flatMap(UUID.init(uuidString:)) else { continue }
              continuation.yield(TranslationLine(id: id, text: response.targetText))
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        // The translation service is launched on demand, and on the first use
        // after an idle period it can accept a batch and never answer. Nothing
        // else bounds this stream, so without a watchdog the caller's spinner
        // runs forever.
        let watchdog = Task {
          try? await ContinuousClock().sleep(for: CaptureDeadline.translationBatch)
          Log.translation.error("Batch of \(lines.count, privacy: .public) lines (\(pair, privacy: .public)) stalled")
          continuation.finish(throwing: DeadlineExceededError(stage: .translation))
        }
        continuation.onTermination = { _ in
          watchdog.cancel()
          // `task.cancel()` alone doesn't stop work already handed to the
          // translation daemon — `cancel()` is the documented way to stop a
          // session's ongoing work. Without it, every live tick whose batch
          // outruns the capture interval abandons a session that keeps working
          // daemon-side, and they accumulate for the life of the process.
          session.cancel()
          task.cancel()
        }
      }
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
