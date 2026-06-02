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
    /// Show the idle hint once after the overlay is enabled. Cleared once a
    /// capture/Live session starts, so toggling Live just shows a transparent
    /// overlay rather than the guide again.
    var showGuide = true
    var translationCache = [TranslationCacheKey: String]()

    @Shared(.overlayFrame) var overlayFrame
    @Shared(.settings) var settings
  }

  enum Action {
    case captureResponse(Result<OCRResult, any Error>)
    case copyTranslationRequested
    case selectRegionRequested
    case overlayToggled(Bool)
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
      case .overlayToggled(let enabled):
        // Drop any stale capture across the transition, and show the idle hint
        // once when the overlay is (re-)enabled.
        state.overlayLines = []
        state.isTranslating = false
        state.showGuide = enabled
        return .cancel(id: CancelID.translation)

      case .selectRegionRequested:
        return .run { _ in
          guard let rect = await regionSelector.selectRegion() else { return }
          await regionResult.present(rect)
        }

      case .captureResponse(.failure(let error)):
        state.isCapturing = false
        state.lastError = error.localizedDescription
        if let screenError = error as? ScreenCaptureError, screenError == .permissionRequired {
          state.isLive = false
          return .cancel(id: CancelID.live)
        }
        return .none

      case .captureResponse(.success(let result)):
        state.isCapturing = false
        state.lastError = nil
        return applyOCRResult(result, into: &state)

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
        if isLive, !state.settings.overlay.enabled {
          state.isLive = false
          state.isCapturing = false
          return .cancel(id: CancelID.live)
        }
        state.isLive = isLive
        state.isCapturing = isLive
        // Toggling Live discards stale results so the overlay doesn't keep
        // showing the previous capture across the transition. The guide never
        // shows for Live toggles — just a transparent overlay.
        state.overlayLines = []
        state.isTranslating = false
        state.showGuide = false
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

  private func applyOCRResult(_ result: OCRResult, into state: inout State) -> Effect<Action> {
    guard !result.lines.isEmpty else {
      state.overlayLines = []
      state.isTranslating = false
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
    state.isTranslating = !groups.isEmpty

    if groups.isEmpty {
      return .cancel(id: CancelID.translation)
    }

    let batches = Array(groups.values)
    return .run { send in
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
  }

  private func runCapture(
    settings: AppSettings,
    overlayFrame: OverlayFrame,
    excludedWindowIDs: [CGWindowID]
  ) async throws -> OCRResult {
    let region = settings.overlay.enabled ? overlayFrame.rect : nil
    let image = try await screenCapture.captureImage(
      region,
      excludedWindowIDs,
      displayID(coveringMostOf: overlayFrame.rect),
      Bundle.main.bundleIdentifier
    )
    return try await ocr.recognizeText(image, settings.languages.source, settings.recognition.mode)
  }
}
