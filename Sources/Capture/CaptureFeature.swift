// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import CoreGraphics
import Foundation
import Sharing

// MARK: - CaptureFeature

@Reducer
struct CaptureFeature {

  // MARK: Internal

  enum CancelID {
    case live
    case translation
  }

  /// One live capture: the screenshot (for the detached Window mode) plus the
  /// recognized lines and their sampled source appearance.
  struct LiveCapture: Sendable {
    var imageData: Data?
    var imageSize: CGSize
    var result: OCRResult
  }

  struct TranslationCacheKey: Hashable, Sendable {
    var source: String
    var strategy: TranslationStrategy
    var target: String
    var text: String
  }

  struct TranslationRequestContext: Equatable, Sendable {
    var strategy: TranslationStrategy
    var target: String
  }

  @ObservableState
  struct State: Equatable {
    var isCapturing = false
    var isLive = false
    var isTranslating = false
    /// The first capture of this live session is taking long enough to need
    /// explaining — practically always Vision loading a cold document model.
    /// Without it the overlay is a bare frame with a spinner and reads as broken.
    var isPreparingRecognition = false
    var lastError: String?
    /// True when a translation failed — almost always a missing on-device model.
    /// Drives the "open Settings" hint in the menu bar.
    var translationUnavailable = false
    var overlayLines = [OverlayLine]()
    /// Raw screenshot shown by the detached Window mode. In-place mode only
    /// needs the sampled appearance carried by each OCR line.
    var sourceImageData: Data?
    var imageSize = CGSize.zero
    /// Whether a live overlay is currently placed on screen. There's no overlay
    /// until the user selects a region/window; `dismissOverlay` clears it.
    var overlayActive = false
    /// Bumped each time the overlay is (re)placed, so the window controller knows
    /// to snap to the new frame even when it's already on screen.
    var overlayPlacementID = 0
    /// Invalidates late responses from a cancelled live tick. Line IDs are
    /// deliberately reused for visual stability, so identity alone cannot tell
    /// an old translation from the current request.
    var translationGeneration = 0
    var translationCache = [TranslationCacheKey: TranslatedText]()
    var translationRequestContext: TranslationRequestContext?

    @Shared(.overlayFrame) var overlayFrame
    @Shared(.settings) var settings
  }

  enum Action {
    case captureIsTakingLong
    case captureResponse(Result<LiveCapture, any Error>)
    case copyTranslationRequested
    case dismissOverlay
    case selectRegionRequested
    case liveSelectRequested
    case overlayPlaced(CGRect)
    case setLive(Bool)
    case toggleLiveRequested
    case toggleLiveOverlayRequested
    case translationUnavailable(generation: Int, lineIDs: Set<UUID>, message: String?)
    case translationResponse(generation: Int, lineID: UUID, key: TranslationCacheKey, translation: TranslatedText)
  }

  @Dependency(\.continuousClock) var clock
  @Dependency(\.languageDetection) var languageDetection
  @Dependency(\.ocr) var ocr
  @Dependency(\.regionResult) var regionResult
  @Dependency(\.regionSelector) var regionSelector
  @Dependency(\.screenCapture) var screenCapture
  @Dependency(\.translation) var translation
  @Dependency(\.uuid) var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .dismissOverlay:
        state.translationGeneration += 1
        state.overlayActive = false
        state.isLive = false
        state.isCapturing = false
        state.isTranslating = false
        state.translationRequestContext = nil
        state.overlayLines = []
        state.sourceImageData = nil
        state.isPreparingRecognition = false
        state.lastError = nil
        state.translationUnavailable = false
        return .merge(
          .cancel(id: CancelID.live),
          .cancel(id: CancelID.translation)
        )

      case .selectRegionRequested:
        return .merge(
          warmUpVision(),
          .run { _ in
            guard let target = await regionSelector.selectRegion(initialMode: .region) else { return }
            await regionResult.present(target)
          }
        )

      case .liveSelectRequested:
        // Same drag-to-select (Space toggles to window mode) as a region
        // capture, but the result snaps a live overlay onto the selection.
        return .merge(
          warmUpVision(),
          .run { send in
            guard let target = await regionSelector.selectRegion(initialMode: .region) else { return }
            await send(.overlayPlaced(target.frame))
          }
        )

      case .overlayPlaced(let frame):
        state.$overlayFrame.withLock { $0 = OverlayFrame(rect: frame) }
        state.overlayActive = true
        state.overlayPlacementID += 1
        return .send(.setLive(true))

      case .captureIsTakingLong:
        // Only while this live session's very first capture is still outstanding;
        // isCapturing is cleared by the first response either way.
        guard state.isLive, state.isCapturing else { return .none }
        state.isPreparingRecognition = true
        return .none

      case .captureResponse(.failure(let error)):
        state.isCapturing = false
        state.isPreparingRecognition = false
        state.lastError = error.localizedDescription
        if let screenError = error as? ScreenCaptureError, screenError == .permissionRequired {
          state.isLive = false
          return .cancel(id: CancelID.live)
        }
        return .none

      case .captureResponse(.success(let capture)):
        state.isCapturing = false
        state.isPreparingRecognition = false
        state.lastError = nil
        state.imageSize = capture.imageSize
        return applyOCRResult(capture, into: &state)

      case .copyTranslationRequested:
        let text = state.overlayLines
          .map(\.displayedText)
          .filter { !$0.isEmpty }
          .joined(separator: "\n")
        guard !text.isEmpty else { return .none }
        return .run { _ in
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }

      case .setLive(let isLive):
        if isLive, !state.overlayActive {
          state.isLive = false
          state.isCapturing = false
          return .cancel(id: CancelID.live)
        }
        state.isLive = isLive
        state.isCapturing = isLive
        // Toggling Live discards stale results so the overlay doesn't keep
        // showing the previous capture across the transition.
        state.overlayLines = []
        state.translationGeneration += 1
        state.isTranslating = false
        state.translationRequestContext = nil
        state.isPreparingRecognition = false
        state.translationUnavailable = false
        if isLive {
          return .merge(
            .cancel(id: CancelID.translation),
            .run { [clock] send in
              // If the first capture hasn't landed by now, say why instead of
              // leaving an empty frame with a spinner on it.
              try await clock.sleep(for: .seconds(2))
              await send(.captureIsTakingLong)
            },
            .run { [
              ocr,
              settings = state.$settings,
              overlayFrame = state.$overlayFrame
            ] send in
              // Serialize the probe and first real recognition. Starting both
              // against a cold Vision daemon made the first capture slower and
              // could leave two expensive document requests competing.
              await ocr.warmUp()
              while !Task.isCancelled {
                let snapshot = settings.wrappedValue
                let frame = overlayFrame.wrappedValue
                // Every stage inside runCapture is deadline-bounded, so a tick
                // that stalls fails and the loop moves on to the next one. An
                // unbounded tick used to park this loop for good: no retry, no
                // error, and isCapturing left true — the overlay just spun.
                let result = await Result {
                  try await runCapture(
                    settings: snapshot,
                    overlayFrame: frame
                  )
                }
                if case .failure(let error) = result {
                  Log.capture.error("Live tick failed: \(error.localizedDescription, privacy: .public)")
                }
                await send(.captureResponse(result))
                try await clock.sleep(for: .seconds(snapshot.capture.interval))
              }
            }
            .cancellable(id: CancelID.live, cancelInFlight: true)
          )
        } else {
          return .merge(.cancel(id: CancelID.live), .cancel(id: CancelID.translation))
        }

      case .toggleLiveRequested:
        guard state.overlayActive else { return .none }
        return .send(.setLive(!state.isLive))

      case .toggleLiveOverlayRequested:
        // Flip the live overlay on/off on the last-used region without
        // re-selecting. When it's up, tear it down via dismissOverlay — that
        // cancels the live-capture loop, the translation task group, and the
        // source restoration, so no capture/OCR/translation keeps running while
        // it's off. Otherwise re-place it on the remembered frame (persisted in
        // overlay-frame.json) and go live.
        if state.overlayActive {
          return .send(.dismissOverlay)
        }
        return .send(.overlayPlaced(state.overlayFrame.rect))

      case .translationUnavailable(let generation, let lineIDs, let message):
        guard generation == state.translationGeneration else { return .none }
        for index in state.overlayLines.indices where lineIDs.contains(state.overlayLines[index].id) {
          state.overlayLines[index].showUnavailable()
        }
        state.isTranslating = state.overlayLines.contains(where: \.isPending)
        if !state.isTranslating {
          state.translationRequestContext = nil
        }
        state.lastError = message ?? "Translation did not return every requested line."
        if message != nil {
          state.translationUnavailable = true
        }
        return .none

      case .translationResponse(let generation, let lineID, let key, let translation):
        guard generation == state.translationGeneration else { return .none }
        let text = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
          if let index = state.overlayLines.firstIndex(where: { $0.id == lineID }) {
            state.overlayLines[index].showUnavailable()
          }
          state.isTranslating = state.overlayLines.contains(where: \.isPending)
          if !state.isTranslating {
            state.translationRequestContext = nil
          }
          state.lastError = "Translation returned empty text."
          return .none
        }
        let translation = TranslatedText(
          text: text,
          attributedText: text == translation.text ? translation.attributedText : nil
        )
        state.translationCache[key] = translation
        if
          let index = state.overlayLines.firstIndex(where: { $0.id == lineID }),
          state.overlayLines[index].isPending
        {
          state.overlayLines[index].showTranslation(
            translation.text,
            attributedText: translation.attributedText,
            language: Locale.Language(identifier: key.target)
          )
        }
        state.isTranslating = state.overlayLines.contains(where: \.isPending)
        if !state.isTranslating {
          state.translationRequestContext = nil
        }
        if !state.isTranslating, !state.overlayLines.contains(where: \.isUnavailable) {
          // Every requested line resolved, so a previous missing-model warning
          // is stale even if this live session started with a failed tick.
          state.translationUnavailable = false
        }
        return .none
      }
    }
  }

  // MARK: Private

  private static func normalizedCenterDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
  }

  /// Starts loading Vision's document model alongside whatever the user is about
  /// to do. Picking a region takes a second or two, and a cold model costs far
  /// more than that (see `VisionWarmUp`), so overlapping the two shortens — and
  /// usually removes — the wait that follows. Cheap when it's already warm.
  private func warmUpVision() -> Effect<Action> {
    .run { [ocr] _ in await ocr.warmUp() }
  }

  private func applyOCRResult(_ capture: LiveCapture, into state: inout State) -> Effect<Action> {
    let result = capture.result
    let windowMode = state.settings.overlay.liveMode == .window

    guard !result.lines.isEmpty else {
      state.translationGeneration += 1
      state.overlayLines = []
      state.isTranslating = false
      state.translationRequestContext = nil
      state.sourceImageData = nil
      return .cancel(id: CancelID.translation)
    }

    let configured = state.settings.languages.source
    let targetLanguage = state.settings.languages.target
    let target = targetLanguage.localeLanguage
    let strategy = state.settings.translation.strategy
    let cache = state.translationCache
    // Auto resolves a source per line (with a whole-capture fallback for short
    // lines); an explicit source applies to every line. A line already in the
    // target language shows its source text instead of being translated.
    let lineSources = languageDetection.resolveSources(for: result.lines.map(\.text), configured: configured)
    let previousMatches = matchedPreviousLines(
      for: result.lines,
      languages: lineSources,
      in: state.overlayLines
    )
    let stableSources = result.lines.indices.map { index in
      let source = OverlayLine.Source(
        recognized: result.lines[index],
        language: lineSources[index].localeLanguage
      )
      guard let previous = previousMatches[index] else { return source }
      return source.stabilized(relativeTo: previous.source, imageSize: capture.imageSize)
    }
    let preservesSource = stableSources.indices.map {
      OverlayTranslationPolicy.preservesSource(at: $0, in: stableSources)
    }
    let sourceSetIsUnchanged = result.lines.count == state.overlayLines.count
      && previousMatches.allSatisfy { $0 != nil }
    if
      state.isTranslating,
      sourceSetIsUnchanged,
      state.translationRequestContext == TranslationRequestContext(
        strategy: strategy,
        target: targetLanguage.code
      )
    {
      // Keep the in-flight batch alive. Replacing it every live tick meant a
      // batch slower than the capture interval could be cancelled and restarted
      // forever. Geometry/style may still change, so refresh only the source
      // side while preserving each line's pending/translated content and id.
      state.overlayLines = result.lines.indices.compactMap { index in
        guard var previous = previousMatches[index] else { return nil }
        previous.source = stableSources[index]
        return previous
      }
      state.sourceImageData = windowMode ? capture.imageData : nil
      return .none
    }

    state.translationGeneration += 1
    let generation = state.translationGeneration

    var newLines = [OverlayLine]()
    var keys = [UUID: TranslationCacheKey]()
    // Pending translations grouped by source language (one session per group).
    var groups = [String: (source: Locale.Language, items: [TranslationLine])]()

    for (index, line) in result.lines.enumerated() {
      let source = lineSources[index].localeLanguage
      let sameLanguage = source.usesSameWritingSystem(as: target)
      let translationLine = TranslationLine(
        id: previousMatches[index]?.id ?? uuid(),
        text: line.text,
        attributedText: stableSources[index].attributedTextForTranslation(),
        trailingContext: OverlayTranslationPolicy.trailingContext(at: index, in: stableSources)
      )
      let key = TranslationCacheKey(
        source: source.maximalIdentifier,
        strategy: strategy,
        target: targetLanguage.code,
        text: translationLine.requestText
      )
      let needsTranslation = !sameLanguage && !preservesSource[index]
      let cached = needsTranslation ? cache[key] : nil

      var overlayLine = OverlayLine(
        id: translationLine.id,
        source: stableSources[index],
        initialContent: needsTranslation ? .pending : .source
      )
      if let cached {
        overlayLine.showTranslation(
          cached.text,
          attributedText: cached.attributedText,
          language: target
        )
      }

      newLines.append(overlayLine)
      if overlayLine.isPending {
        keys[overlayLine.id] = key
        groups[source.maximalIdentifier, default: (source, [])].items
          .append(translationLine)
      }
    }

    state.overlayLines = newLines
    state.sourceImageData = windowMode ? capture.imageData : nil

    state.isTranslating = !groups.isEmpty
    if groups.isEmpty {
      state.translationRequestContext = nil
      state.translationUnavailable = false
      return .cancel(id: CancelID.translation)
    }

    let batches = Array(groups.values)
    let translationKeys = keys
    state.translationRequestContext = TranslationRequestContext(
      strategy: strategy,
      target: targetLanguage.code
    )
    return Effect<Action>.run { send in
      // One session per source language; each response or explicit fallback
      // resolves a replacement and the last pending line clears the spinner.
      await withTaskGroup(of: Void.self) { group in
        for batch in batches {
          group.addTask {
            var remaining = Set(batch.items.map(\.id))
            do {
              for try await result in translation.translateBatch(batch.items, batch.source, target, strategy) {
                remaining.remove(result.id)
                if let key = translationKeys[result.id] {
                  await send(
                    .translationResponse(
                      generation: generation,
                      lineID: result.id,
                      key: key,
                      translation: TranslatedText(
                        text: result.text,
                        attributedText: result.attributedText
                      )
                    )
                  )
                }
              }
            } catch is CancellationError {
              return
            } catch {
              guard !remaining.isEmpty else { return }
              await send(
                .translationUnavailable(
                  generation: generation,
                  lineIDs: remaining,
                  message: error.localizedDescription
                )
              )
              return
            }
            if !remaining.isEmpty {
              await send(.translationUnavailable(generation: generation, lineIDs: remaining, message: nil))
            }
          }
        }
      }
    }
    .cancellable(id: CancelID.translation, cancelInFlight: true)
  }

  /// Matches duplicate source strings by geometry rather than array position.
  /// Vision is free to change observation order between frames; positional
  /// matching swapped identities on repeated labels and made SwiftUI replace
  /// otherwise stable text views.
  private func matchedPreviousLines(
    for lines: [OCRResult.Line],
    languages: [Language],
    in previousLines: [OverlayLine]
  ) -> [OverlayLine?] {
    var remaining = Array(previousLines.indices)
    return lines.indices.map { index in
      let language = languages[index].localeLanguage.maximalIdentifier
      let candidates = remaining.filter { previousIndex in
        let previous = previousLines[previousIndex]
        return previous.source.text == lines[index].text
          && previous.source.language.maximalIdentifier == language
      }
      guard
        let match = candidates.min(by: { lhs, rhs in
          Self.normalizedCenterDistance(lines[index].boundingBoxNormalized, previousLines[lhs].source.box)
            < Self.normalizedCenterDistance(lines[index].boundingBoxNormalized, previousLines[rhs].source.box)
        })
      else { return nil }
      remaining.removeAll { $0 == match }
      return previousLines[match]
    }
  }

  private func runCapture(
    settings: AppSettings,
    overlayFrame: OverlayFrame
  ) async throws -> LiveCapture {
    // The live overlay is always placed over a region while running. Exclude
    // this process so the transparent overlay never becomes the next OCR input.
    //
    // Both stages are bounded separately so the log names whichever one stalled:
    // ScreenCaptureKit and Vision each talk to a daemon that is cold on the first
    // use after an idle period and can stop answering entirely.
    let image = try await withDeadline(
      CaptureDeadline.screenCapture,
      stage: .screenCapture,
      clock: clock
    ) { [screenCapture] in
      try await screenCapture.captureImage(
        overlayFrame.rect,
        displayID(coveringMostOf: overlayFrame.rect),
        ProcessInfo.processInfo.processIdentifier
      )
    }
    let result = try await withDeadline(CaptureDeadline.ocr, stage: .ocr, clock: clock) { [ocr] in
      try await ocr.recognizeText(image, settings.languages.source)
    }
    // Only carry the screenshot when Window mode displays a detached result.
    let needsImage = settings.overlay.liveMode == .window
    return LiveCapture(
      imageData: needsImage ? image.pngData : nil,
      imageSize: CGSize(width: image.width, height: image.height),
      result: result
    )
  }
}
