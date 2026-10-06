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
    case preparation
    case recognition
    case translation
  }

  /// One live capture: the backdrop (for the detached Window mode) plus the
  /// recognized lines and their sampled source appearance.
  struct LiveCapture: Sendable {
    var backdrop: OverlayBackdrop?
    var imageSize: CGSize
    var result: OCRResult
  }

  struct TranslationCacheKey: Hashable, Sendable {
    var source: String
    var strategy: TranslationStrategy
    var target: String
    var text: String
    var attributedText: AttributedString? = nil
    var groupContext: TranslationGroupContext.Member? = nil
  }

  struct TranslationRequestContext: Equatable, Sendable {
    var strategy: TranslationStrategy
    var target: String
    var imageSize: CGSize
    var sources: [UUID: OverlayLine.Source]
    var groupContexts = [UUID: TranslationGroupContext.Member]()

    func matches(
      _ sources: [OverlayLine.Source],
      previous: [OverlayLine?],
      imageSize: CGSize,
      groupContexts: [Int: TranslationGroupContext.Member]? = nil
    ) -> Bool {
      let currentGroups = groupContexts ?? TranslationGroupContext.associations(in: sources)
      guard self.imageSize == imageSize, self.sources.count == sources.count else { return false }
      return sources.indices.allSatisfy { index in
        guard let id = previous[index]?.id, let requested = self.sources[id] else { return false }
        return sources[index].canReuseTranslation(relativeTo: requested, imageSize: imageSize)
          && self.groupContexts[id] == currentGroups[index]
      }
    }
  }

  @ObservableState
  struct State: Equatable {
    var isCapturing = false
    var isLive = false
    var isTranslating = false
    /// The first recognition is taking long enough to show a processing hint.
    /// Elapsed time alone cannot identify model loading or any other cause.
    var isPreparingRecognition = false
    var lastError: String?
    /// True when a translation failed — almost always a missing on-device model.
    /// Drives the "open Settings" hint in the menu bar.
    var translationUnavailable = false
    var overlayLines = [OverlayLine]()
    /// Captured pixels shown by the detached Window mode. In-place mode only
    /// needs the sampled appearance carried by each OCR line.
    var backdrop: OverlayBackdrop?
    var imageSize = CGSize.zero
    /// Whether a live overlay is currently placed on screen. There's no overlay
    /// until the user selects a region/window; `dismissOverlay` clears it.
    var overlayActive = false
    /// Bumped each time the overlay is (re)placed, so the window controller knows
    /// to snap to the new frame even when it's already on screen.
    var overlayPlacementID = 0
    /// A window selection remains bound to that window for this app session.
    /// Region selections and persisted frames have no window identity.
    var sourceWindowID: CGWindowID?
    var sourceWindowAvailable = true
    /// Invalidates late responses from a cancelled live tick. Line IDs are
    /// deliberately reused for visual stability, so identity alone cannot tell
    /// an old translation from the current request.
    var translationGeneration = 0
    var captureGeneration = 0
    var recognitionGeneration = 0
    var lastFrameSignature: LiveFrame.Signature?
    var recognitionSettings: LiveFrame.Settings?
    /// Keep at most the running/last recognized frame and the newest pending
    /// frame. Continuous pixel changes must not starve OCR by cancelling it.
    var visualSourceWitnesses = [UUID: LiveFrame.Witness]()
    var recognitionFrame: LiveFrame?
    var pendingRecognitionFrame: LiveFrame?
    var recognitionInFlight = false
    var isSourceInteracting = false
    var translationCacheOrder = [TranslationCacheKey]()
    var translationCache = [TranslationCacheKey: TranslatedText]()
    var translationRequestContext: TranslationRequestContext?

    @Shared(.overlayFrame) var overlayFrame
    @Shared(.settings) var settings
  }

  enum Action {
    case captureIsTakingLong
    case liveFrameResponse(generation: Int, frame: OverlayFrame, result: Result<LiveFrame, any Error>)
    case liveCaptureResponse(generation: Int, frame: OverlayFrame, result: Result<LiveCapture, any Error>)
    case sourceInteractionBegan
    case sourceInteractionEnded
    case translationFinished(generation: Int)
    case copyTranslationRequested
    case dismissOverlay
    case selectRegionRequested
    case liveSelectRequested
    case overlayPlaced(CGRect)
    case liveTargetSelected(CaptureTarget)
    case sourceWindowGeometryChanged(id: CGWindowID, frame: CGRect?)
    case sourceWindowClosed(id: CGWindowID)
    case setLive(Bool)
    case toggleLiveRequested
    case setOverlayVisible(Bool)
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
        state.captureGeneration += 1
        state.recognitionGeneration += 1
        state.lastFrameSignature = nil
        state.recognitionSettings = nil
        state.recognitionFrame = nil
        state.pendingRecognitionFrame = nil
        state.recognitionInFlight = false
        state.isSourceInteracting = false
        state.translationGeneration += 1
        state.overlayActive = false
        state.isLive = false
        state.isCapturing = false
        state.isTranslating = false
        state.translationRequestContext = nil
        state.overlayLines = []
        state.visualSourceWitnesses = [:]
        state.backdrop = nil
        state.isPreparingRecognition = false
        state.lastError = nil
        state.translationUnavailable = false
        return .merge(
          .cancel(id: CancelID.live),
          .cancel(id: CancelID.recognition),
          .cancel(id: CancelID.preparation),
          .cancel(id: CancelID.translation)
        )

      case .selectRegionRequested:
        return .run { _ in
          guard let target = await regionSelector.selectRegion(initialMode: .region) else { return }
          await regionResult.present(target)
        }

      case .liveSelectRequested:
        // Same drag-to-select (Space toggles to window mode) as a region
        // capture, but the result snaps a live overlay onto the selection.
        return selectLiveTarget(initialMode: .region)

      case .liveTargetSelected(let target):
        if case .window(let id, _) = target { state.sourceWindowID = id }
        else { state.sourceWindowID = nil }
        state.sourceWindowAvailable = true
        let kind: OverlayFrame.SelectionKind = state.sourceWindowID == nil ? .region : .window
        state.$overlayFrame.withLock { $0 = OverlayFrame(rect: target.frame, selectionKind: kind) }
        state.overlayActive = true
        state.overlayPlacementID += 1
        return .send(.setLive(true))

      case .sourceWindowClosed(let id):
        guard state.overlayActive, state.sourceWindowID == id else { return .none }
        state.sourceWindowID = nil
        state.$overlayFrame.withLock { $0.hasSelection = false }
        return .send(.dismissOverlay)

      case .sourceWindowGeometryChanged(let id, let frame):
        guard state.overlayActive, state.sourceWindowID == id else { return .none }
        guard state.sourceWindowAvailable != (frame != nil) || frame.map({ $0 != state.overlayFrame.rect }) == true else {
          return .none
        }
        state.sourceWindowAvailable = frame != nil
        if let frame { state.$overlayFrame.withLock { $0.updateGeometry(frame) } }
        // Retire every old-frame request in this action, before the new frame
        // can be displayed. Desired Live state survives temporary minimization.
        return setLive(state.isLive, into: &state)

      case .overlayPlaced(let frame):
        state.sourceWindowID = nil
        state.sourceWindowAvailable = true
        state.$overlayFrame.withLock { $0 = OverlayFrame(rect: frame) }
        state.overlayActive = true
        state.overlayPlacementID += 1
        return .send(.setLive(true))

      case .sourceInteractionBegan:
        guard state.isLive, !state.isSourceInteracting else { return .none }
        state.isSourceInteracting = true
        state.captureGeneration += 1
        state.recognitionGeneration += 1
        state.lastFrameSignature = nil
        state.recognitionSettings = nil
        state.recognitionFrame = nil
        state.pendingRecognitionFrame = nil
        state.recognitionInFlight = false
        state.translationGeneration += 1
        state.overlayLines = []
        state.visualSourceWitnesses = [:]
        state.backdrop = nil
        state.isCapturing = false
        state.isTranslating = false
        state.isPreparingRecognition = false
        state.translationRequestContext = nil
        return .merge(
          .cancel(id: CancelID.live),
          .cancel(id: CancelID.recognition),
          .cancel(id: CancelID.preparation),
          .cancel(id: CancelID.translation)
        )

      case .sourceInteractionEnded:
        guard state.isSourceInteracting else { return .none }
        state.isSourceInteracting = false
        guard state.isLive, state.overlayActive else { return .none }
        return .send(.setLive(true))

      case .liveFrameResponse(let generation, let frame, let result):
        guard
          state.isLive, !state.isSourceInteracting,
          generation == state.captureGeneration, frame == state.overlayFrame
        else { return .none }
        switch result {
        case .failure(let error):
          return captureFailed(error, into: &state)
        case .success(let snapshot):
          let settings = LiveFrame.Settings(state.settings)
          // The capture loop never waits for OCR. Unchanged pixels retain the
          // current recognition/translation, including an in-flight request.
          guard snapshot.signature != state.lastFrameSignature || settings != state.recognitionSettings else {
            return .none
          }
          state.lastFrameSignature = snapshot.signature
          let invalidate = settings != state.recognitionSettings
            || (state.recognitionFrame.map { snapshot.imageSize != $0.imageSize } ?? true)
          if invalidate {
            state.pendingRecognitionFrame = nil
            state.translationGeneration += 1
            state.translationRequestContext = nil
            state.overlayLines = []
            state.visualSourceWitnesses = [:]
            state.backdrop = nil
            state.isTranslating = false
            return .merge(
              .cancel(id: CancelID.translation),
              recognize(snapshot, settings: settings, frame: frame, into: &state)
            )
          }
          refreshVisualFreshness(snapshot, into: &state)
          // Pixel changes, including video compression, do not establish a
          // text change. Finish OCR and apply its semantic result before
          // recognizing the latest pending frame, so continuous video cannot
          // starve recognition. Only pixel-matching regions remain painted.
          if state.recognitionInFlight {
            state.pendingRecognitionFrame = snapshot == state.recognitionFrame ? nil : snapshot
            return .none
          }
          return recognize(snapshot, settings: settings, frame: frame, into: &state)
        }

      case .liveCaptureResponse(let generation, let frame, let result):
        guard
          state.isLive, !state.isSourceInteracting,
          generation == state.recognitionGeneration,
          frame == state.overlayFrame
        else { return .none }
        // This request has finished even when its settings are no longer
        // applicable. Leaving it marked in-flight would strand pending frames
        // if the user switches settings back before the next capture tick.
        state.recognitionInFlight = false
        guard state.recognitionSettings == LiveFrame.Settings(state.settings) else {
          state.recognitionGeneration += 1
          state.lastFrameSignature = nil
          state.recognitionSettings = nil
          state.recognitionFrame = nil
          state.pendingRecognitionFrame = nil
          state.translationGeneration += 1
          state.translationRequestContext = nil
          state.overlayLines = []
          state.visualSourceWitnesses = [:]
          state.backdrop = nil
          state.isCapturing = false
          state.isTranslating = false
          state.isPreparingRecognition = false
          return .merge(.cancel(id: CancelID.preparation), .cancel(id: CancelID.translation))
        }
        // Validate and apply in the same reducer action. Forwarding an untagged
        // response allowed a queued scroll/dismissal to invalidate it in between.
        switch result {
        case .success(let capture):
          let applied = captureSucceeded(capture, into: &state)
          if let recognizedFrame = state.recognitionFrame {
            state.visualSourceWitnesses = Dictionary(uniqueKeysWithValues: state.overlayLines.compactMap { line in
              recognizedFrame.witness(for: line.source).map { (line.id, $0) }
            })
            refreshVisualFreshness(state.pendingRecognitionFrame ?? recognizedFrame, into: &state)
          }
          guard let pending = state.pendingRecognitionFrame else { return applied }
          state.pendingRecognitionFrame = nil
          return .merge(
            applied,
            recognize(pending, settings: LiveFrame.Settings(state.settings), frame: frame, into: &state)
          )

        case .failure(let error):
          return captureFailed(error, into: &state)
        }

      case .captureIsTakingLong:
        // Only while this live session's very first capture is still outstanding;
        // isCapturing is cleared by the first response either way.
        guard state.isLive, state.isCapturing else { return .none }
        state.isPreparingRecognition = true
        return .none

      case .copyTranslationRequested:
        let text = state.overlayLines
          .filter(\.sourcePixelsAreCurrent)
          .map(\.displayedText)
          .filter { !$0.isEmpty }
          .joined(separator: "\n")
        guard !text.isEmpty else { return .none }
        return .run { _ in
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }

      case .setLive(let requested):
        return setLive(requested, into: &state)

      case .toggleLiveRequested:
        guard state.overlayActive else { return .none }
        return .send(.setLive(!state.isLive))

      case .setOverlayVisible(let visible):
        guard visible != state.overlayActive else { return .none }
        return .send(.toggleLiveOverlayRequested)

      case .toggleLiveOverlayRequested:
        // Hiding retires all capture/recognition/translation work. A remembered
        // region can be recalled directly; a remembered window needs its
        // session identity or a fresh selection after the app restarts.
        if state.overlayActive {
          return .send(.dismissOverlay)
        }
        guard state.overlayFrame.hasSelection else { return .none }
        if state.overlayFrame.selectionKind == .window {
          guard let id = state.sourceWindowID else { return selectLiveTarget(initialMode: .window) }
          return .send(.liveTargetSelected(.window(id: id, frame: state.overlayFrame.rect)))
        }
        return .send(.overlayPlaced(state.overlayFrame.rect))

      case .translationFinished(let generation):
        guard generation == state.translationGeneration else { return .none }
        state.translationRequestContext = nil
        return .none

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
        state.translationCacheOrder.removeAll { $0 == key }
        state.translationCacheOrder.append(key)
        state.translationCache[key] = translation
        if state.translationCacheOrder.count > 512 {
          state.translationCache.removeValue(forKey: state.translationCacheOrder.removeFirst())
        }
        if
          let index = state.overlayLines.firstIndex(where: { $0.id == lineID })
        {
          state.overlayLines[index].showTranslation(
            translation.text,
            attributedText: translation.attributedText,
            language: Locale.Language(identifier: key.target)
          )
        }
        state.isTranslating = state.overlayLines.contains(where: \.isPending)
        if !state.isTranslating, !state.overlayLines.contains(where: \.isUnavailable) {
          // Every requested line resolved, so a previous missing-model warning
          // is stale even if this live session started with a failed tick.
          state.translationUnavailable = false
          state.lastError = nil
        }
        return .none
      }
    }
  }

  // MARK: Private

  private static func normalizedCenterDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
  }

  private func applyOCRResult(_ capture: LiveCapture, into state: inout State) -> Effect<Action> {
    let result = capture.result
    let windowMode = state.settings.overlay.liveMode == .window

    let verifiedBounds: [UUID: CGRect] =
      if let frame = state.recognitionFrame, frame.imageSize == capture.imageSize {
        state.visualSourceWitnesses.compactMapValues { frame.matches($0) ? $0.bounds : nil }
      } else { [:] }

    guard !result.lines.isEmpty || !verifiedBounds.isEmpty else {
      state.translationGeneration += 1
      state.overlayLines = []
      state.visualSourceWitnesses = [:]
      state.isTranslating = false
      state.translationRequestContext = nil
      state.backdrop = nil
      return .cancel(id: CancelID.translation)
    }

    let configured = state.settings.languages.source
    let targetLanguage = state.settings.languages.target
    let target = targetLanguage.localeLanguage
    let strategy = state.settings.translation.strategy
    let cache = state.translationCache
    // Auto resolves a source per line, using its independent input as context
    // for short lines; an explicit source applies to every line. A line already in the
    // target language shows its source text instead of being translated.
    let lineSources = languageDetection.resolveRecognizedSources(for: result.lines, configured: configured)
    let observations = result.lines.indices.map { index in
      OverlayLine.Source(recognized: result.lines[index], language: lineSources[index].localeLanguage)
    }
    let rawSources = LiveSourceIdentity.sources(observations, previous: state.overlayLines, verifiedBounds: verifiedBounds)
    let previousMatches = matchedPreviousLines(for: rawSources, in: state.overlayLines)
    let stableSources = rawSources.indices.map { index in
      guard let previous = previousMatches[index] else { return rawSources[index] }
      return rawSources[index].stabilized(relativeTo: previous.source, imageSize: capture.imageSize)
    }
    let contextGroups = TranslationGroupContext.associations(in: stableSources)
    let preservesSource = stableSources.indices.map {
      OverlayTranslationPolicy.preservesSource(at: $0, in: stableSources)
    }
    let sourceSetIsUnchanged = rawSources.count == state.overlayLines.count
      && previousMatches.allSatisfy { $0 != nil }
    if
      let context = state.translationRequestContext,
      sourceSetIsUnchanged,
      context.strategy == strategy,
      context.target == targetLanguage.code,
      context.matches(rawSources, previous: previousMatches, imageSize: capture.imageSize, groupContexts: contextGroups)
    {
      // Keep the in-flight batch alive. Replacing it every live tick meant a
      // batch slower than the capture interval could be cancelled and restarted
      // forever. Geometry/style may still change, so refresh only the source
      // side while preserving each line's pending/translated content and id.
      state.overlayLines = rawSources.indices.compactMap { index in
        guard var previous = previousMatches[index] else { return nil }
        previous.source = stableSources[index]
        return previous
      }
      state.backdrop = windowMode ? capture.backdrop : nil
      return .none
    }

    state.translationGeneration += 1
    let generation = state.translationGeneration

    var newLines = [OverlayLine]()
    var keys = [UUID: TranslationCacheKey]()
    // Pending translations grouped by source language (one session per group).
    var groups = [String: (source: Locale.Language, items: [TranslationLine])]()

    for (index, line) in stableSources.enumerated() {
      let source = line.language
      let sameLanguage = source.usesSameWritingSystem(as: target)
      let translationLine = TranslationLine(
        id: previousMatches[index]?.id ?? uuid(),
        text: line.text,
        attributedText: stableSources[index].attributedTextForTranslation(),
        trailingContext: contextGroups[index] == nil
          ? OverlayTranslationPolicy.trailingContext(at: index, in: stableSources)
          : nil,
        groupContext: contextGroups[index]
      )
      let key = TranslationCacheKey(
        source: source.maximalIdentifier,
        strategy: strategy,
        target: targetLanguage.code,
        text: translationLine.requestText,
        attributedText: translationLine.attributedText,
        groupContext: translationLine.groupContext
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
    state.backdrop = windowMode ? capture.backdrop : nil

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
      target: targetLanguage.code,
      imageSize: capture.imageSize,
      sources: Dictionary(uniqueKeysWithValues: zip(newLines, rawSources).map { ($0.id, $1) }),
      groupContexts: Dictionary(uniqueKeysWithValues: newLines.indices.compactMap { index in
        contextGroups[index].map { (newLines[index].id, $0) }
      })
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
                try Task.checkCancellation()
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
              guard !Task.isCancelled, !remaining.isEmpty else { return }
              await send(
                .translationUnavailable(
                  generation: generation,
                  lineIDs: remaining,
                  message: error.localizedDescription
                )
              )
              return
            }
            if !Task.isCancelled, !remaining.isEmpty {
              await send(.translationUnavailable(generation: generation, lineIDs: remaining, message: nil))
            }
          }
        }
      }
      guard !Task.isCancelled else { return }
      await send(.translationFinished(generation: generation))
    }
    .cancellable(id: CancelID.translation, cancelInFlight: true)
  }

  /// Matches duplicate source strings by geometry rather than array position.
  /// Vision is free to change observation order between frames; positional
  /// matching swapped identities on repeated labels and made SwiftUI replace
  /// otherwise stable text views.
  private func matchedPreviousLines(
    for lines: [OverlayLine.Source],
    in previousLines: [OverlayLine]
  ) -> [OverlayLine?] {
    var remaining = Array(previousLines.indices)
    return lines.indices.map { index in
      let language = lines[index].language.maximalIdentifier
      let candidates = remaining.filter { previousIndex in
        let previous = previousLines[previousIndex]
        return previous.source.text == lines[index].text
          && previous.source.language.maximalIdentifier == language
      }
      guard
        let match = candidates.min(by: { lhs, rhs in
          Self.normalizedCenterDistance(lines[index].box, previousLines[lhs].source.box)
            < Self.normalizedCenterDistance(lines[index].box, previousLines[rhs].source.box)
        })
      else { return nil }
      remaining.removeAll { $0 == match }
      return previousLines[match]
    }
  }

  private func refreshVisualFreshness(_ snapshot: LiveFrame, into state: inout State) {
    // Detached mode paints onto its matching captured backdrop, not the live desktop.
    guard state.settings.overlay.liveMode != .window else { return }
    for index in state.overlayLines.indices {
      guard let witness = state.visualSourceWitnesses[state.overlayLines[index].id] else {
        state.overlayLines[index].sourcePixelsAreCurrent = false
        continue
      }
      state.overlayLines[index].sourcePixelsAreCurrent = snapshot.matches(witness)
    }
  }

  private func captureSucceeded(_ capture: LiveCapture, into state: inout State) -> Effect<Action> {
    state.isCapturing = false
    state.isPreparingRecognition = false
    state.lastError = nil
    state.imageSize = capture.imageSize
    return .merge(.cancel(id: CancelID.preparation), applyOCRResult(capture, into: &state))
  }

  private func recognize(
    _ snapshot: LiveFrame,
    settings: LiveFrame.Settings,
    frame: OverlayFrame,
    into state: inout State
  ) -> Effect<Action> {
    state.recognitionGeneration += 1
    state.recognitionFrame = snapshot
    state.recognitionSettings = settings
    state.recognitionInFlight = true
    state.isCapturing = state.overlayLines.isEmpty
    state.lastError = nil
    let generation = state.recognitionGeneration
    return .run { [ocr, clock] send in
      let result = await Result {
        let recognized = try await withDeadline(CaptureDeadline.ocr, stage: .ocr, clock: clock) {
          try Task.checkCancellation()
          return try await ocr.recognizeText(snapshot.backdrop.image, settings.source)
        }
        try Task.checkCancellation()
        return LiveCapture(
          backdrop: settings.mode == .window ? snapshot.backdrop : nil,
          imageSize: snapshot.imageSize,
          result: recognized
        )
      }
      try Task.checkCancellation()
      await send(.liveCaptureResponse(generation: generation, frame: frame, result: result))
    }
    .cancellable(id: CancelID.recognition, cancelInFlight: true)
  }

  private func captureFailed(_ error: any Error, into state: inout State) -> Effect<Action> {
    state.recognitionGeneration += 1
    state.lastFrameSignature = nil // Retry even when the next pixels are identical.
    state.recognitionFrame = nil
    state.pendingRecognitionFrame = nil
    state.recognitionInFlight = false
    state.isCapturing = false
    state.isPreparingRecognition = false
    state.lastError = error.localizedDescription
    state.translationGeneration += 1
    state.translationRequestContext = nil
    state.overlayLines = []
    state.visualSourceWitnesses = [:]
    state.backdrop = nil
    state.isTranslating = false
    if error as? ScreenCaptureError == .permissionRequired {
      state.isLive = false
    }
    return .merge(
      .cancel(id: CancelID.preparation),
      .cancel(id: CancelID.recognition),
      .cancel(id: CancelID.translation),
      state.isLive ? .none : .cancel(id: CancelID.live)
    )
  }

  private func selectLiveTarget(initialMode: SelectionMode) -> Effect<Action> {
    .run { send in
      guard let target = await regionSelector.selectRegion(initialMode: initialMode) else { return }
      await send(.liveTargetSelected(target))
    }
  }

  private func setLive(_ requested: Bool, into state: inout State) -> Effect<Action> {
    let isLive = requested && state.overlayActive
    state.captureGeneration += 1
    state.recognitionGeneration += 1
    state.lastFrameSignature = nil
    state.recognitionSettings = nil
    state.recognitionFrame = nil
    state.pendingRecognitionFrame = nil
    state.recognitionInFlight = false
    state.isSourceInteracting = false
    state.isLive = isLive
    state.isCapturing = isLive
    state.lastError = nil
    // Toggling Live discards stale results so the overlay doesn't keep
    // showing the previous capture across the transition.
    state.overlayLines = []
    state.visualSourceWitnesses = [:]
    state.backdrop = nil
    state.translationGeneration += 1
    state.isTranslating = false
    state.translationRequestContext = nil
    state.isPreparingRecognition = false
    state.translationUnavailable = false
    if isLive, state.sourceWindowAvailable {
      let generation = state.captureGeneration
      return .merge(
        .cancel(id: CancelID.recognition),
        .cancel(id: CancelID.translation),
        .run { [clock] send in
          // If the first capture hasn't landed by now, say why instead of
          // leaving an empty frame with a spinner on it.
          try await clock.sleep(for: .seconds(2))
          await send(.captureIsTakingLong)
        }
        .cancellable(id: CancelID.preparation, cancelInFlight: true),
        .run { [clock, overlayFrame = state.$overlayFrame, windowID = state.sourceWindowID] send in
          // Elapsed work and the remaining delay share the injected timebase.
          let cadenceClock = AnyClock(clock)
          var cadence = LiveCaptureCadence()
          while !Task.isCancelled {
            let tickStarted = cadenceClock.now
            let frame = overlayFrame.wrappedValue
            // Capture has its own deadline. OCR runs in another effect,
            // so even a cold Vision model cannot stop change detection.
            let result = await Result {
              if let windowID {
                let captured = try await withDeadline(CaptureDeadline.screenCapture, stage: .screenCapture, clock: clock) {
                  try await screenCapture.captureWindowSnapshot(windowID)
                }
                var capturedFrame = frame
                capturedFrame.updateGeometry(captured.frame)
                return (capturedFrame, try LiveFrame(image: captured.image))
              }
              return (frame, try await captureFrame(overlayFrame: frame))
            }
            try Task.checkCancellation()
            if case .failure(let error) = result {
              Log.capture.error("Live tick failed: \(error.localizedDescription, privacy: .public)")
            }
            await send(.liveFrameResponse(
              generation: generation,
              frame: (try? result.get().0) ?? frame,
              result: result.map { $0.1 }
            ))
            let elapsed = tickStarted.duration(to: cadenceClock.now)
            if
              let delay = LiveCaptureCadence.remainingDelay(
                interval: cadence.interval(after: try? result.get().1.signature),
                elapsed: elapsed
              )
            {
              try await clock.sleep(for: delay)
            }
          }
        }
        .cancellable(id: CancelID.live, cancelInFlight: true)
      )
    } else {
      return .merge(
        .cancel(id: CancelID.live),
        .cancel(id: CancelID.recognition),
        .cancel(id: CancelID.preparation),
        .cancel(id: CancelID.translation)
      )
    }
  }

  private func captureFrame(overlayFrame: OverlayFrame) async throws -> LiveFrame {
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
    try Task.checkCancellation()
    return try LiveFrame(image: image)
  }
}

// MARK: - LiveCaptureCadence

struct LiveCaptureCadence {

  // MARK: Internal

  /// Keeps the adaptive interval start-to-start. Processing time already
  /// consumes part of the interval and must not be added to it again.
  static func remainingDelay(interval: Duration, elapsed: Duration) -> Duration? {
    guard elapsed < interval else { return nil }
    return interval - elapsed
  }

  /// Rapidly follow an active screen, then avoid repeatedly waking the capture
  /// daemon at that rate for a static page. Gestures bypass this delay by
  /// restarting the loop. Errors back off without parking it permanently.
  mutating func interval(after signature: LiveFrame.Signature?) -> Duration {
    guard let signature else {
      failures = min(3, failures + 1)
      unchangedSamples = 0
      return .milliseconds(500 * (1 << (failures - 1)))
    }
    failures = 0
    unchangedSamples = signature == previousSignature ? min(3, unchangedSamples + 1) : 0
    previousSignature = signature
    return unchangedSamples >= 3 ? .milliseconds(500) : .milliseconds(150)
  }

  // MARK: Private

  private var previousSignature: LiveFrame.Signature?
  private var unchangedSamples = 0
  private var failures = 0

}
