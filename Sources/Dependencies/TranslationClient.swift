// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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
  var attributedText: AttributedString? = nil
}

// MARK: - TranslatedText

struct TranslatedText: Equatable, Sendable {
  var text: String
  var attributedText: AttributedString? = nil
}

// MARK: - TranslationTextStructure

enum TranslationTextStructure {

  // MARK: Internal

  /// Translation may promote one source line break into a paragraph break.
  /// Keep the target's wording, but cap consecutive newlines to the structure
  /// that OCR recovered from the source frame.
  static func matchingSourceBreaks(_ target: String, source: String) -> String {
    let sourceLimit = maximumConsecutiveNewlines(in: source)
    guard sourceLimit > 0 else { return target }

    let normalized = target
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var result = ""
    var consecutiveNewlines = 0
    for character in normalized {
      if character == "\n" {
        if consecutiveNewlines < sourceLimit {
          result.append(character)
        }
        consecutiveNewlines += 1
      } else {
        consecutiveNewlines = 0
        result.append(character)
      }
    }
    return result
  }

  // MARK: Private

  private static func maximumConsecutiveNewlines(in text: String) -> Int {
    var maximum = 0
    var current = 0
    for character in text {
      if character == "\n" {
        current += 1
        maximum = max(maximum, current)
      } else if character != "\r" {
        current = 0
      }
    }
    return maximum
  }
}

// MARK: - TranslationClient

@DependencyClient
struct TranslationClient {
  /// Translates all `lines` in one source-language session, yielding each result
  /// as soon as it's ready (order isn't guaranteed; match by `id`). Translation
  /// always comes from the plain batch response. Attributed source text is used
  /// only to map visual style spans onto that translated string.
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

  // MARK: Internal

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
        let linesByID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let requests = lines.map {
          TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
        }
        let task = Task {
          let clock = ContinuousClock()
          let started = clock.now
          var receivedFirstResponse = false
          do {
            var styledTargets = [UUID: String]()
            for try await response in session.translate(batch: requests) {
              if !receivedFirstResponse {
                receivedFirstResponse = true
                let elapsed = clock.now - started
                Log.translation.debug(
                  "First response for \(pair, privacy: .public) arrived in \(elapsed.loggedSeconds, privacy: .public)s"
                )
              }
              guard
                let id = response.clientIdentifier.flatMap(UUID.init(uuidString:)),
                let sourceLine = linesByID[id]
              else { continue }
              let targetText = TranslationTextStructure.matchingSourceBreaks(
                response.targetText,
                source: sourceLine.text
              )
              if #available(macOS 26.4, *), sourceLine.attributedText != nil {
                styledTargets[id] = targetText
                continue
              }
              continuation.yield(TranslationLine(
                id: id,
                text: targetText
              ))
            }
            if #available(macOS 26.4, *), !styledTargets.isEmpty {
              try await Self.yieldStyledTranslations(
                styledTargets,
                linesByID: linesByID,
                session: session,
                continuation: continuation
              )
            }
            let elapsed = clock.now - started
            Log.translation.debug(
              "Batch of \(lines.count, privacy: .public) lines (\(pair, privacy: .public)) finished in \(elapsed.loggedSeconds, privacy: .public)s"
            )
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
          do {
            try await ContinuousClock().sleep(for: CaptureDeadline.translationBatch)
          } catch {
            return
          }
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

  // MARK: Private

  @available(macOS 26.4, *)
  private static func yieldStyledTranslations(
    _ targets: [UUID: String],
    linesByID: [UUID: TranslationLine],
    session: TranslationSession,
    continuation: AsyncThrowingStream<TranslationLine, any Error>.Continuation
  ) async throws {
    var alternatives = [UUID: [URL: String]]()
    var snippetOwners = [UUID: (lineID: UUID, link: URL)]()
    var snippetRequests = [TranslationSession.Request]()

    for (lineID, targetText) in targets {
      guard let source = linesByID[lineID]?.attributedText else { continue }
      let alignment = TranslationStyleMapper.align(source: source, target: targetText)
      for span in alignment.unmatched {
        let requestID = UUID()
        snippetOwners[requestID] = (lineID, span.link)
        snippetRequests.append(TranslationSession.Request(
          sourceText: span.text,
          clientIdentifier: requestID.uuidString
        ))
      }
    }

    if !snippetRequests.isEmpty {
      for try await response in session.translate(batch: snippetRequests) {
        guard
          let requestID = response.clientIdentifier.flatMap(UUID.init(uuidString:)),
          let owner = snippetOwners[requestID]
        else { continue }
        alternatives[owner.lineID, default: [:]][owner.link] = response.targetText
      }
    }

    for (lineID, targetText) in targets {
      guard
        let sourceLine = linesByID[lineID],
        let attributedSource = sourceLine.attributedText
      else { continue }
      let alignment = TranslationStyleMapper.align(
        source: attributedSource,
        target: targetText,
        alternatives: alternatives[lineID] ?? [:]
      )
      if !alignment.unmatched.isEmpty {
        Log.translation.debug(
          "Dropping \(alignment.unmatched.count, privacy: .public) unaligned style runs while preserving the plain translation"
        )
      }
      continuation.yield(TranslationLine(
        id: lineID,
        text: targetText,
        attributedText: alignment.target
      ))
    }
  }
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
