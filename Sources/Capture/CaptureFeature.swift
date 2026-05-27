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
    var translationCache = [TranslationCacheKey: String]()

    @Shared(.overlayFrame) var overlayFrame
    @Shared(.settings) var settings
  }

  enum Action {
    case captureResponse(Result<OCRResult, any Error>)
    case clearResults
    case copyTranslationRequested
    case selectRegionRequested
    case setExcludedWindowIDs([CGWindowID])
    case setLive(Bool)
    case toggleLiveRequested
    case translationResponse(lineID: UUID, key: TranslationCacheKey, Result<String, any Error>)
  }

  @Dependency(\.continuousClock) var clock
  @Dependency(OCRClient.self) var ocr
  @Dependency(\.regionResult) var regionResult
  @Dependency(\.regionSelector) var regionSelector
  @Dependency(ScreenCaptureClient.self) var screenCapture
  @Dependency(TranslationClient.self) var translation
  @Dependency(\.uuid) var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .clearResults:
        state.overlayLines = []
        state.isTranslating = false
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
        return .send(.setLive(!state.isLive))

      case .translationResponse(_, _, .failure(let error)):
        state.lastError = error.localizedDescription
        state.isTranslating = state.overlayLines.contains { $0.translated == nil }
        return .none

      case .translationResponse(let lineID, let key, .success(let translated)):
        state.translationCache[key] = translated
        if let index = state.overlayLines.firstIndex(where: { $0.id == lineID }) {
          state.overlayLines[index].translated = translated
        }
        state.isTranslating = state.overlayLines.contains { $0.translated == nil }
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

    let source = state.settings.languages.source.localeLanguage
    let target = state.settings.languages.target.localeLanguage
    let strategy = state.settings.translation.strategy
    let cache = state.translationCache

    // Reuse line identity when the source text matches the previous OCR
    // pass, so SwiftUI's transitions stay stable across live captures.
    let previousByText = Dictionary(grouping: state.overlayLines, by: \.sourceText)
      .mapValues { Array($0.reversed()) }

    var reused = previousByText
    var newLines = [OverlayLine]()
    var pending = [(line: OverlayLine, key: TranslationCacheKey)]()

    for line in result.lines {
      let key = TranslationCacheKey(
        source: source.maximalIdentifier,
        strategy: strategy,
        target: state.settings.languages.target.code,
        text: line.text
      )
      let cached = cache[key]

      var overlayLine: OverlayLine
      if var bucket = reused[line.text], let recycled = bucket.popLast() {
        overlayLine = recycled
        overlayLine.box = line.boundingBoxNormalized
        if let cached {
          overlayLine.translated = cached
        }
        reused[line.text] = bucket
      } else {
        overlayLine = OverlayLine(
          id: uuid(),
          box: line.boundingBoxNormalized,
          sourceText: line.text,
          translated: cached
        )
      }

      newLines.append(overlayLine)
      if overlayLine.translated == nil {
        pending.append((overlayLine, key))
      }
    }

    state.overlayLines = newLines
    state.isTranslating = !pending.isEmpty

    if pending.isEmpty {
      return .cancel(id: CancelID.translation)
    }

    return .run { send in
      await withTaskGroup(of: Void.self) { group in
        for item in pending {
          group.addTask {
            await send(
              .translationResponse(
                lineID: item.line.id,
                key: item.key,
                Result {
                  try await translation.translate(
                    item.line.sourceText,
                    source,
                    target,
                    strategy
                  )
                }
              )
            )
          }
        }
      }
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
