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
  /// Neighboring compact value used only to disambiguate this label. It is
  /// never rendered as part of the label's translated output.
  var trailingContext: String? = nil
  var groupContext: TranslationGroupContext.Member? = nil

  var requestText: String {
    guard let trailingContext else { return text }
    return "\(text): \(trailingContext)"
  }
}

// MARK: - TranslatedText

struct TranslatedText: Equatable, Sendable {
  var text: String
  var attributedText: AttributedString? = nil
}

// MARK: - TranslationTextStructure

enum TranslationTextStructure {

  // MARK: Internal

  /// A replacement character is evidence of a malformed model response, not
  /// wording that should overwrite readable source pixels. A missing yield is
  /// reported by the caller's incomplete-batch handling after other lines finish.
  static func isUsableResponse(_ text: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !text.contains("\u{FFFD}")
  }

  /// Translation may promote one source line break into a paragraph break.
  /// Keep the target's wording, but cap consecutive newlines to the structure
  /// that OCR recovered from the source frame.
  static func matchingSourceBreaks(_ target: String, source: String) -> String {
    // Keep a terminal footnote attached to its preceding word. The translation
    // service can introduce a space that lets the mark wrap onto its own line.
    let target = source.last.map { "*†‡".contains($0) } == true
      ? target.replacingOccurrences(of: #"\s+([*†‡])$"#, with: "$1", options: .regularExpression)
      : target
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

  /// Extracts the label from a contextual `label: value` translation. Apple
  /// Translation retains either the ASCII or full-width colon for supported
  /// language pairs; nil rejects a response whose context cannot be separated
  /// from the label, rather than displaying neighboring content in its place.
  static func label(fromContextualTranslation target: String) -> String? {
    guard let separator = target.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
      return nil
    }
    let label = target[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
    return label.isEmpty ? nil : label
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
  /// comes from the unchanged prose request with existing code literals restored.
  /// Optional style alignment never changes that resulting prose.
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
        let linesByID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let literalPlans = Dictionary(uniqueKeysWithValues: lines.compactMap { line in
          TranslationLiteralPlan(line.attributedText).map { (line.id, $0) }
        })
        let contextualLines = Dictionary(grouping: lines.filter { line in
          guard
            #available(macOS 26.4, *), literalPlans[line.id] == nil, line.trailingContext == nil,
            let member = line.groupContext, member.context.labels.indices.contains(member.index),
            member.context.labels[member.index] == line.text, member.context.attributedRequest != nil
          else { return false }
          return true
        }) { $0.groupContext!.context }
        let contextualIDs = Set(contextualLines.values.flatMap { $0.map(\.id) })
        func requests(for items: [TranslationLine]) -> [TranslationSession.Request] {
          items.map {
            var request = $0
            request.text = literalPlans[$0.id]?.requestText ?? $0.text
            var native = TranslationSession.Request(sourceText: request.requestText, clientIdentifier: $0.id.uuidString)
            if #available(macOS 26.4, *), $0.trailingContext == nil {
              native.attributedSourceText = literalPlans[$0.id]?.requestAttributedText ?? $0.attributedText
            }
            return native
          }
        }
        let task = Task {
          let clock = ContinuousClock()
          let started = clock.now
          var receivedFirstResponse = false
          do {
            try await TranslationModelResolver.validateSelection(source: source, target: target, strategy: strategy)
            try Task.checkCancellation()
            let session =
              if #available(macOS 26.4, *) {
                TranslationSession(installedSource: source, target: target, preferredStrategy: strategy.sessionStrategy)
              } else {
                TranslationSession(installedSource: source, target: target)
              }
            try await withTaskCancellationHandler {
              var styledTargets = [UUID: String]()
              var anchoredTargets = [UUID: AttributedString]()
              func accept(_ responseText: String, id: UUID, metadata: AttributedString? = nil) throws {
                try Task.checkCancellation()
                if !receivedFirstResponse {
                  receivedFirstResponse = true
                  let elapsed = clock.now - started
                  Log.translation.debug(
                    "First response for \(pair, privacy: .public) arrived in \(elapsed.loggedSeconds, privacy: .public)s"
                  )
                }
                guard let sourceLine = linesByID[id] else { return }
                guard TranslationTextStructure.isUsableResponse(responseText) else {
                  Log.translation.error("Rejected malformed translation response for \(pair, privacy: .public)")
                  return
                }
                let translatedLabel = sourceLine.trailingContext == nil
                  ? responseText
                  : TranslationTextStructure.label(fromContextualTranslation: responseText)
                guard let translatedLabel else {
                  Log.translation.error("Rejected translation with missing context separator for \(pair, privacy: .public)")
                  return
                }
                let normalizedTarget = TranslationTextStructure.matchingSourceBreaks(
                  translatedLabel,
                  source: sourceLine.text
                )
                let nativeMetadata = metadata.flatMap { String($0.characters) == normalizedTarget ? $0 : nil }
                let restored: AttributedString
                if let plan = literalPlans[id] {
                  guard let decoded = plan.restoring(nativeMetadata ?? AttributedString(normalizedTarget)) else {
                    Log.translation
                      .error("Rejected translation with invalid protected text markers for \(pair, privacy: .public)")
                    return
                  }
                  restored = decoded
                  anchoredTargets[id] = decoded
                } else { restored = nativeMetadata ?? AttributedString(normalizedTarget)
                  if nativeMetadata != nil { anchoredTargets[id] = restored }
                }
                let targetText = String(restored.characters)
                var attributedTarget = anchoredTargets[id]
                var requiresSourceAlignment = false
                if let attributedSource = sourceLine.attributedText {
                  let alignment = TranslationStyleMapper.align(
                    source: attributedSource,
                    target: targetText,
                    preserving: anchoredTargets[id]
                  )
                  attributedTarget = alignment.target
                  requiresSourceAlignment = alignment.hasUnmappedSourceFragments
                  anchoredTargets[id] = alignment.target
                  if !alignment.unmatched.isEmpty { styledTargets[id] = targetText }
                }
                // Optional styles do not delay prose. Captured pixels require
                // complete target ownership before their source can be erased.
                if !requiresSourceAlignment {
                  continuation.yield(TranslationLine(id: id, text: targetText, attributedText: attributedTarget))
                }
              }
              let ordinary = lines.filter { !contextualIDs.contains($0.id) }
              if !ordinary.isEmpty {
                for try await response in session.translate(batch: requests(for: ordinary)) {
                  guard let id = response.clientIdentifier.flatMap(UUID.init(uuidString:)) else { continue }
                  if #available(macOS 26.4, *) {
                    try accept(response.targetText, id: id, metadata: response.attributedTargetText)
                  } else { try accept(response.targetText, id: id) }
                }
              }
              if #available(macOS 26.4, *) {
                for (context, members) in contextualLines {
                  try Task.checkCancellation()
                  let response = try await session.translate(context.attributedRequest!)
                  try Task.checkCancellation()
                  if let targets = context.targets(from: response.attributedTargetText) {
                    for member in members { try accept(targets[member.groupContext!.index], id: member.id) }
                  } else {
                    // Some language pairs omit attributed ownership. Do not
                    // guess item order or render the translated topic as a label.
                    Log.translation.notice("Context group ownership unavailable; translating independent labels")
                    for try await response in session.translate(batch: requests(for: members)) {
                      guard let id = response.clientIdentifier.flatMap(UUID.init(uuidString:)) else { continue }
                      try accept(response.targetText, id: id)
                    }
                  }
                }
              }
              if !styledTargets.isEmpty {
                try await Self.yieldStyledTranslations(
                  styledTargets,
                  linesByID: linesByID,
                  session: session,
                  continuation: continuation,
                  preserving: anchoredTargets
                )
              }
              let elapsed = clock.now - started
              Log.translation.debug(
                "Batch of \(lines.count, privacy: .public) lines (\(pair, privacy: .public)) finished in \(elapsed.loggedSeconds, privacy: .public)s"
              )
              continuation.finish()
            } onCancel: { session.cancel() }
          } catch {
            continuation.finish(throwing: TranslationModelResolver.explaining(error, source: source, target: target))
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
          task.cancel()
        }
      }
    }
  )

  /// Native metadata is optional evidence. A failed lookup must not discard
  /// other paragraphs' anchors or prevent lexical/contextual alignment.
  static func aligningNativeStyles(
    _ targets: [UUID: String],
    linesByID: [UUID: TranslationLine],
    preserving: [UUID: AttributedString],
    translate: (AttributedString) async throws -> AttributedString?
  ) async throws -> [UUID: AttributedString] {
    var anchors = preserving
    for (id, target) in targets {
      try Task.checkCancellation()
      guard
        let source = linesByID[id]?.attributedText,
        !TranslationStyleMapper.align(source: source, target: target, preserving: anchors[id]).unmatched.isEmpty
      else { continue }
      do {
        let literalPlan = TranslationLiteralPlan(source)
        let response = try await translate(literalPlan?.requestAttributedText ?? source)
        let native: AttributedString? =
          if let literalPlan { response.flatMap { literalPlan.restoring($0) } }
          else { response }
        try Task.checkCancellation()
        anchors[id] = TranslationStyleMapper.alignNativeStyles(
          source: source,
          target: target,
          native: native,
          preserving: anchors[id]
        ).target
      } catch {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
        Log.translation.error("Optional native style alignment failed: \(String(describing: error), privacy: .public)")
      }
    }
    return anchors
  }

  // MARK: Private

  private static func yieldStyledTranslations(
    _ targets: [UUID: String],
    linesByID: [UUID: TranslationLine],
    session: TranslationSession,
    continuation: AsyncThrowingStream<TranslationLine, any Error>.Continuation,
    preserving: [UUID: AttributedString]
  ) async throws {
    var anchors = preserving
    if #available(macOS 26.4, *) {
      anchors = try await aligningNativeStyles(targets, linesByID: linesByID, preserving: anchors) {
        try await session.translate($0).attributedTargetText
      }
    }
    // Lexical matches and sentence-context matches are complementary evidence.
    // Deduplicate repeated link labels across the batch before asking for them.
    var owners = [String: [(id: UUID, link: URL)]]()
    for (id, target) in targets {
      guard let source = linesByID[id]?.attributedText else { continue }
      for span in TranslationStyleMapper.align(source: source, target: target, preserving: anchors[id]).unmatched
        where !span.isLiteral
      {
        owners[span.text, default: []].append((id, span.link))
      }
    }
    let terms = owners.keys.sorted()
    let lexicalRequests = terms.enumerated().map {
      TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
    }
    var alternatives = [UUID: [URL: String]]()
    if !lexicalRequests.isEmpty {
      for try await response in session.translate(batch: lexicalRequests) {
        try Task.checkCancellation()
        guard let index = response.clientIdentifier.flatMap(Int.init), terms.indices.contains(index) else { continue }
        for owner in owners[terms[index]] ?? [] { alternatives[owner.id, default: [:]][owner.link] = response.targetText }
      }
    }
    let requests = targets.keys.compactMap { id -> TranslationSession.Request? in
      guard let source = linesByID[id]?.attributedText, let target = targets[id] else { return nil }
      let alignment = TranslationStyleMapper.align(
        source: source,
        target: target,
        alternatives: alternatives[id] ?? [:],
        preserving: anchors[id]
      )
      anchors[id] = alignment.target
      if !alignment.hasUnmappedSourceFragments {
        continuation.yield(TranslationLine(id: id, text: target, attributedText: alignment.target))
      }
      let unresolved = Set(alignment.unmatched
        .filter { !$0.isLiteral && ($0.isSourceFragment || $0.text.contains(where: \.isLetter)) }.map(\.link))
      guard
        !unresolved.isEmpty,
        let contextual = TranslationStyleMapper.ownershipRequest(source: source)
        ?? TranslationStyleMapper.contextualRequest(source: source, links: unresolved)
      else { return nil }
      return TranslationSession.Request(sourceText: contextual, clientIdentifier: id.uuidString)
    }
    guard !requests.isEmpty else { return }
    for try await response in session.translate(batch: requests) {
      try Task.checkCancellation()
      guard
        let id = response.clientIdentifier.flatMap(UUID.init(uuidString:)),
        let source = linesByID[id]?.attributedText, let target = targets[id]
      else { continue }
      if let formatted = TranslationStyleMapper.contextualTranslation(source: source, response: response.targetText) {
        continuation.yield(TranslationLine(id: id, text: String(formatted.characters), attributedText: formatted))
        continue
      }
      let alignment = TranslationStyleMapper.alignContextual(
        source: source,
        target: target,
        response: response.targetText,
        alternatives: alternatives[id] ?? [:],
        preserving: anchors[id]
      )
      if !alignment.unmatched.isEmpty {
        Log.translation.debug("Could not align \(alignment.unmatched.count, privacy: .public) contextual style runs")
      }
      if !alignment.hasUnmappedSourceFragments {
        continuation.yield(TranslationLine(id: id, text: target, attributedText: alignment.target))
      } else {
        Log.translation.error("Could not establish required source-fragment alignment")
      }
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
