// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CustomDump
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Capture translation lifecycle")
@MainActor
struct CaptureFeatureTests {

  // MARK: Internal

  @Test
  func lateResponseFromCancelledGenerationIsIgnored() async {
    let store = TestStore(initialState: makeState()) {
      CaptureFeature()
    }

    await store.send(
      CaptureFeature.Action.translationResponse(
        generation: 1,
        lineID: pendingLine.id,
        key: cacheKey,
        translation: TranslatedText(text: "Stale translation")
      )
    )
  }

  @Test
  func currentResponseResolvesPendingLineAndCachesOnlyNonemptyText() async {
    let store = TestStore(initialState: makeState()) {
      CaptureFeature()
    }

    await store.send(
      CaptureFeature.Action.translationResponse(
        generation: 2,
        lineID: pendingLine.id,
        key: cacheKey,
        translation: TranslatedText(text: "  Current translation  ")
      )
    ) {
      $0.translationCache[cacheKey] = TranslatedText(text: "Current translation")
      $0.translationCacheOrder = [cacheKey]
      $0.overlayLines[0].showTranslation(
        "Current translation",
        language: Locale.Language(identifier: "en-US")
      )
      $0.isTranslating = false
    }
  }

  @Test
  func emptyResponseBecomesVisibleErrorWithoutPoisoningCache() async {
    let store = TestStore(initialState: makeState()) {
      CaptureFeature()
    }

    await store.send(
      CaptureFeature.Action.translationResponse(
        generation: 2,
        lineID: pendingLine.id,
        key: cacheKey,
        translation: TranslatedText(text: " \n ")
      )
    ) {
      $0.overlayLines[0].showUnavailable()
      $0.isTranslating = false
      $0.lastError = "Translation returned empty text."
    }
  }

  @Test
  func omittedResultBecomesExplicitFallback() async {
    let store = TestStore(initialState: makeState()) {
      CaptureFeature()
    }

    await store.send(
      CaptureFeature.Action.translationUnavailable(
        generation: 2,
        lineIDs: [pendingLine.id],
        message: nil
      )
    ) {
      $0.overlayLines[0].showUnavailable()
      $0.isTranslating = false
      $0.lastError = "Translation did not return every requested line."
    }
  }

  @Test
  func unchangedLiveOCRKeepsInFlightTranslationAndRefreshesSourceStyle() async {
    var state = makeState()
    state.$settings.withLock {
      $0.languages.source = Language(code: "ja")
      $0.languages.target = Language(code: "en-US")
    }
    state.translationRequestContext = CaptureFeature.TranslationRequestContext(
      strategy: .lowLatency,
      target: "en-US",
      imageSize: CGSize(width: 900, height: 600),
      sources: [pendingLine.id: pendingLine.source]
    )
    state.isLive = true
    state.recognitionSettings = LiveFrame.Settings(state.settings)
    let appearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1),
      foreground: OverlayColor(red: 0.8, green: 0.7, blue: 0.6, alpha: 1),
      confidence: 0.9,
      foregroundConfidence: 0.8,
      inkCoverage: 0.25,
      fontWeight: .medium
    )
    let refreshed = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.41, y: 0.21, width: 0.08, height: 0.3),
      text: pendingLine.source.text,
      isVerticalBlock: true,
      verticalCharScale: 0.04,
      appearance: appearance
    )
    let capture = CaptureFeature.LiveCapture(
      backdrop: nil,
      imageSize: CGSize(width: 900, height: 600),
      result: OCRResult(lines: [refreshed])
    )
    let expectedSource = OverlayLine.Source(
      recognized: refreshed,
      language: Locale.Language(identifier: "ja")
    ).stabilized(relativeTo: state.overlayLines[0].source, imageSize: capture.imageSize)
    let store = TestStore(initialState: state) {
      CaptureFeature()
    }
    store.dependencies.languageDetection = LanguageDetectionClient(
      detect: { _, _ in nil }
    )

    await store.send(.liveCaptureResponse(generation: 0, frame: state.overlayFrame, result: .success(capture))) {
      $0.imageSize = capture.imageSize
      $0.overlayLines[0].source = expectedSource
    }

    #expect(store.state.translationGeneration == 2)
    #expect(store.state.overlayLines[0].isPending)
    expectNoDifference(store.state.overlayLines[0].source.box, refreshed.boundingBoxNormalized)
  }

  @Test
  func sourceStabilizationAcceptsRealMovementImmediately() {
    let previous = pendingLine.source
    let moved = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.55, y: 0.35, width: 0.08, height: 0.3),
      text: previous.text,
      isVerticalBlock: true,
      verticalCharScale: 0.04
    )
    let current = OverlayLine.Source(recognized: moved, language: previous.language)

    let stabilized = current.stabilized(
      relativeTo: previous,
      imageSize: CGSize(width: 900, height: 600)
    )

    #expect(stabilized.box == moved.boundingBoxNormalized)
  }

  @Test
  func liveCadenceSubtractsWorkAlreadySpentInTheTick() {
    #expect(
      LiveCaptureCadence.remainingDelay(
        interval: .milliseconds(800),
        elapsed: .milliseconds(275)
      ) == .milliseconds(525)
    )
    #expect(
      LiveCaptureCadence.remainingDelay(
        interval: .milliseconds(800),
        elapsed: .milliseconds(800)
      ) == nil
    )
    #expect(
      LiveCaptureCadence.remainingDelay(
        interval: .milliseconds(800),
        elapsed: .seconds(2)
      ) == nil
    )
  }

  @Test
  func cacheEvictsOldestEntryAtCapacity() async {
    var state = makeState()
    for index in 0..<512 {
      var key = cacheKey
      key.text = "Source \(index)"
      state.translationCache[key] = TranslatedText(text: "Translation \(index)")
      state.translationCacheOrder.append(key)
    }
    let oldest = state.translationCacheOrder[0]
    let store = TestStore(initialState: state) { CaptureFeature() }
    store.exhaustivity = .off
    await store.send(.translationResponse(
      generation: 2,
      lineID: pendingLine.id,
      key: cacheKey,
      translation: TranslatedText(text: "Current translation")
    ))
    expectNoDifference(store.state.translationCache.count, 512)
    expectNoDifference(store.state.translationCacheOrder.count, 512)
    #expect(store.state.translationCache[oldest] == nil)
    expectNoDifference(store.state.translationCache[cacheKey]?.text, "Current translation")
  }

  @Test
  func optionalStyleResponseRemainsAcceptedAfterPlainTextAppears() async {
    var state = makeState()
    state.overlayLines[0].source.styleRuns = [OverlaySourceStyleRun(
      range: NSRange(location: 0, length: 2),
      box: pendingLine.source.box,
      appearance: OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .bold)
    )]
    let store = TestStore(initialState: state) { CaptureFeature() }
    store.exhaustivity = .off
    await store.send(.translationResponse(
      generation: 2,
      lineID: pendingLine.id,
      key: cacheKey,
      translation: TranslatedText(text: "Hello")
    ))
    #expect(!store.state.isTranslating)
    var styled = AttributedString("Hello")
    styled.link = URL(string: "swiftycrow-style://run/0")
    await store.send(.translationResponse(
      generation: 2,
      lineID: pendingLine.id,
      key: cacheKey,
      translation: TranslatedText(text: "Hello", attributedText: styled)
    ))
    expectNoDifference(store.state.overlayLines[0].translatedText, "Hello")
    expectNoDifference(store.state.overlayLines[0].displayedStyleRuns.count, 1)
    expectNoDifference(store.state.overlayLines[0].displayedStyleRuns[0].appearance.fontWeight, .bold)
    #expect(!store.state.isTranslating)
  }

  // MARK: Private

  private var cacheKey: CaptureFeature.TranslationCacheKey {
    CaptureFeature.TranslationCacheKey(
      source: "ja-Jpan-JP",
      strategy: .lowLatency,
      target: "en-US",
      text: "今日は大切な話があります"
    )
  }

  private var pendingLine: OverlayLine {
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.4, y: 0.2, width: 0.08, height: 0.3),
      text: "今日は大切な話があります",
      isVerticalBlock: true,
      verticalCharScale: 0.04
    )
    return OverlayLine(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja")
      ),
      initialContent: .pending
    )
  }

  private func makeState() -> CaptureFeature.State {
    var state = CaptureFeature.State()
    state.translationGeneration = 2
    state.isTranslating = true
    state.overlayLines = [pendingLine]
    return state
  }
}
