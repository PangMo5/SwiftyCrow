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
    case background
    case live
    case translation
  }

  /// One live capture: the screenshot (for the Window-mode blurred backdrop)
  /// plus the recognized lines.
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

  @ObservableState
  struct State {
    var excludedWindowIDs = [CGWindowID]()
    var isCapturing = false
    var isLive = false
    var isTranslating = false
    var lastError: String?
    var overlayLines = [OverlayLine]()
    /// Window-mode backdrop: the screenshot with each box blurred. Nil in
    /// In-place mode (the chips draw directly on the overlay).
    var backgroundImageData: Data?
    var imageSize = CGSize.zero
    /// Whether a live overlay is currently placed on screen. There's no overlay
    /// until the user selects a region/window; `dismissOverlay` clears it.
    var overlayActive = false
    /// Bumped each time the overlay is (re)placed, so the window controller knows
    /// to snap to the new frame even when it's already on screen.
    var overlayPlacementID = 0
    var translationCache = [TranslationCacheKey: String]()

    @Shared(.overlayFrame) var overlayFrame
    @Shared(.settings) var settings
  }

  enum Action {
    case backgroundReady(Data?)
    case captureResponse(Result<LiveCapture, any Error>)
    case copyTranslationRequested
    case dismissOverlay
    case selectRegionRequested
    case liveSelectRequested
    case overlayPlaced(CGRect)
    case setExcludedWindowIDs([CGWindowID])
    case setLive(Bool)
    case toggleLiveRequested
    case translationCompleted
    case translationFailed(String)
    case translationResponse(lineID: UUID, key: TranslationCacheKey, translated: String)
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
        state.overlayActive = false
        state.isLive = false
        state.isCapturing = false
        state.isTranslating = false
        state.overlayLines = []
        state.backgroundImageData = nil
        state.lastError = nil
        return .merge(
          .cancel(id: CancelID.live),
          .cancel(id: CancelID.translation),
          .cancel(id: CancelID.background)
        )

      case .selectRegionRequested:
        return .run { _ in
          guard let target = await regionSelector.selectRegion(initialMode: .region) else { return }
          await regionResult.present(target)
        }

      case .liveSelectRequested:
        // Same drag-to-select (Space toggles to window mode) as a region
        // capture, but the result snaps a live overlay onto the selection.
        return .run { send in
          guard let target = await regionSelector.selectRegion(initialMode: .region) else { return }
          await send(.overlayPlaced(target.frame))
        }

      case .overlayPlaced(let frame):
        state.$overlayFrame.withLock { $0 = OverlayFrame(rect: frame) }
        state.overlayActive = true
        state.overlayPlacementID += 1
        return .send(.setLive(true))

      case .captureResponse(.failure(let error)):
        state.isCapturing = false
        state.lastError = error.localizedDescription
        if let screenError = error as? ScreenCaptureError, screenError == .permissionRequired {
          state.isLive = false
          return .cancel(id: CancelID.live)
        }
        return .none

      case .backgroundReady(let data):
        state.backgroundImageData = data
        return .none

      case .captureResponse(.success(let capture)):
        state.isCapturing = false
        state.lastError = nil
        state.imageSize = capture.imageSize
        return applyOCRResult(capture, into: &state)

      case .copyTranslationRequested:
        let text = state.overlayLines
          .compactMap { $0.translated ?? ($0.sourceText.isEmpty ? nil : $0.sourceText) }
          .joined(separator: "\n")
        guard !text.isEmpty else { return .none }
        return .run { _ in
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }

      case .setExcludedWindowIDs(let ids):
        state.excludedWindowIDs = ids
        return .none

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
        state.isTranslating = false
        if isLive {
          return .merge(
            .cancel(id: CancelID.translation),
            .run { [
              settings = state.$settings,
              overlayFrame = state.$overlayFrame,
              excludedWindowIDs = state.excludedWindowIDs
            ] send in
              while !Task.isCancelled {
                let snapshot = settings.wrappedValue
                let frame = overlayFrame.wrappedValue
                await send(
                  .captureResponse(
                    Result {
                      try await runCapture(
                        settings: snapshot,
                        overlayFrame: frame,
                        excludedWindowIDs: excludedWindowIDs
                      )
                    }
                  )
                )
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

      case .translationCompleted:
        state.isTranslating = false
        return .none

      case .translationFailed(let message):
        state.lastError = message
        return .none

      case .translationResponse(let lineID, let key, let translated):
        state.translationCache[key] = translated
        if let index = state.overlayLines.firstIndex(where: { $0.id == lineID }) {
          state.overlayLines[index].translated = translated
        }
        return .none
      }
    }
  }

  // MARK: Private

  private func applyOCRResult(_ capture: LiveCapture, into state: inout State) -> Effect<Action> {
    let result = capture.result
    let windowMode = state.settings.overlay.liveMode == .window

    guard !result.lines.isEmpty else {
      state.overlayLines = []
      state.isTranslating = false
      state.backgroundImageData = nil
      return .merge(.cancel(id: CancelID.translation), .cancel(id: CancelID.background))
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

    // Reuse line identity when the source text matches the previous OCR
    // pass, so SwiftUI's transitions stay stable across live captures.
    let previousByText = Dictionary(grouping: state.overlayLines, by: \.sourceText)
      .mapValues { Array($0.reversed()) }

    var reused = previousByText
    var newLines = [OverlayLine]()
    var keys = [UUID: TranslationCacheKey]()
    // Pending translations grouped by source language (one session per group).
    var groups = [String: (source: Locale.Language, items: [TranslationLine])]()

    for (index, line) in result.lines.enumerated() {
      let source = lineSources[index].localeLanguage
      let sameLanguage = source.languageCode == target.languageCode
      let key = TranslationCacheKey(
        source: source.maximalIdentifier,
        strategy: strategy,
        target: targetLanguage.code,
        text: line.text
      )
      let cached = sameLanguage ? line.text : cache[key]

      var overlayLine: OverlayLine
      if var bucket = reused[line.text], let recycled = bucket.popLast() {
        overlayLine = recycled
        overlayLine.box = line.boundingBoxNormalized
        overlayLine.rowCount = line.rowCount
        if let cached {
          overlayLine.translated = cached
        }
        reused[line.text] = bucket
      } else {
        overlayLine = OverlayLine(
          id: uuid(),
          box: line.boundingBoxNormalized,
          sourceText: line.text,
          translated: cached,
          rowCount: line.rowCount
        )
      }

      newLines.append(overlayLine)
      if overlayLine.translated == nil {
        keys[overlayLine.id] = key
        groups[source.maximalIdentifier, default: (source, [])].items
          .append(TranslationLine(id: overlayLine.id, text: overlayLine.sourceText))
      }
    }

    state.overlayLines = newLines

    // Window mode draws a blurred screenshot backdrop in the detached window;
    // In-place mode draws chips directly on the overlay, so no backdrop.
    let background: Effect<Action>
    if windowMode, let data = capture.imageData {
      let lines = newLines
      let size = capture.imageSize
      background = .run { send in
        // Pure Core Graphics / Core Image — runs off the main actor.
        let bg = blurredBackground(baseData: data, lines: lines, pixelSize: size)
        await send(.backgroundReady(bg))
      }
      .cancellable(id: CancelID.background, cancelInFlight: true)
    } else {
      state.backgroundImageData = nil
      background = .cancel(id: CancelID.background)
    }

    state.isTranslating = !groups.isEmpty
    if groups.isEmpty {
      return .merge(background, .cancel(id: CancelID.translation))
    }

    let batches = Array(groups.values)
    let translate = Effect<Action>.run { send in
      // One session per source language; chips update as results stream back.
      // translationCompleted clears the spinner once every batch finishes.
      await withTaskGroup(of: Void.self) { group in
        for batch in batches {
          group.addTask {
            do {
              for try await result in translation.translateBatch(batch.items, batch.source, target, strategy) {
                if let key = keys[result.id] {
                  await send(.translationResponse(lineID: result.id, key: key, translated: result.text))
                }
              }
            } catch {
              await send(.translationFailed(error.localizedDescription))
            }
          }
        }
      }
      await send(.translationCompleted)
    }
    .cancellable(id: CancelID.translation, cancelInFlight: true)
    return .merge(background, translate)
  }

  private func runCapture(
    settings: AppSettings,
    overlayFrame: OverlayFrame,
    excludedWindowIDs: [CGWindowID]
  ) async throws -> LiveCapture {
    // The live overlay is always placed over a region while running, so capture
    // that region (excluding our own windows via the bundle id below).
    let image = try await screenCapture.captureImage(
      overlayFrame.rect,
      excludedWindowIDs,
      displayID(coveringMostOf: overlayFrame.rect),
      Bundle.main.bundleIdentifier
    )
    let result = try await ocr.recognizeText(image, settings.languages.source, settings.recognition.mode)
    // Only carry the screenshot when Window mode needs it for the backdrop.
    let needsImage = settings.overlay.liveMode == .window
    return LiveCapture(
      imageData: needsImage ? image.pngData : nil,
      imageSize: CGSize(width: image.width, height: image.height),
      result: result
    )
  }
}
