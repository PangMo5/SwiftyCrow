// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import CustomDump
import Foundation
import Testing
import TOML
@testable import SwiftyCrow

@Suite("Live capture freshness")
@MainActor
struct LiveCapturePipelineTests {

  // MARK: Internal

  @Test
  func identicalPixelsSkipOCRAndChangedPixelsCancelPendingRecognition() async throws {
    let first = try LiveFrame(image: image(gray: 0.2))
    let identical = try LiveFrame(image: image(gray: 0.2))
    let changed = try LiveFrame(image: image(gray: 0.7))
    expectNoDifference(first.signature, identical.signature)
    #expect(first.signature != changed.signature)
    let calls = LockIsolated(0)
    let cancellations = LockIsolated(0)
    let clock = TestClock()
    let store = TestStore(initialState: state()) { CaptureFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.ocr = OCRClient(recognizeText: { _, _ in
        calls.withValue { $0 += 1 }
        let stream = AsyncThrowingStream<OCRResult, any Error> { continuation in
          continuation.onTermination = { _ in cancellations.withValue { $0 += 1 } }
        }
        for try await result in stream { return result }
        throw CancellationError()
      }, warmUp: { })
    }
    store.exhaustivity = .off
    let frame = store.state.overlayFrame
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(first)))
    // Let the effect enter its controllable OCR stream.
    for _ in 0..<100 where calls.value < 1 { await Task.yield() }
    expectNoDifference(calls.value, 1)
    let generation = store.state.recognitionGeneration
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(identical)))
    expectNoDifference(store.state.recognitionGeneration, generation)
    expectNoDifference(calls.value, 1)
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(changed)))
    for _ in 0..<100 where cancellations.value < 1 || calls.value < 2 { await Task.yield() }
    expectNoDifference(calls.value, 2)
    expectNoDifference(cancellations.value, 1)
    #expect(store.state.recognitionGeneration > generation)
    await store.send(.dismissOverlay)
    await store.finish()
  }

  @Test
  func captureLoopKeepsSamplingWhileOCRIsSuspended() async throws {
    let clock = TestClock()
    let pixels = try image(gray: 0.4)
    let captures = LockIsolated(0)
    let recognitions = LockIsolated(0)
    let store = TestStore(initialState: state()) { CaptureFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.screenCapture = ScreenCaptureClient(captureImage: { _, _, _ in
        captures.withValue { $0 += 1 }
        return pixels
      }, captureWindow: { _ in pixels })
      $0.ocr = OCRClient(recognizeText: { _, _ in
        recognitions.withValue { $0 += 1 }
        try await clock.sleep(for: .seconds(60))
        return OCRResult(lines: [])
      }, warmUp: { })
    }
    store.exhaustivity = .off
    await store.send(.setLive(true))
    await store.receive(\.liveFrameResponse)
    await clock.advance(by: .seconds(1))
    await store.receive(\.liveFrameResponse)
    #expect(captures.value >= 2)
    expectNoDifference(recognitions.value, 1)
    #expect(store.state.isCapturing)
    await store.send(.dismissOverlay)
    await store.finish()
  }

  @Test
  func scrollInvalidatesBothLateOCRAndLateTranslations() async {
    var initial = state()
    initial.overlayLines = [line()]
    initial.isTranslating = true
    initial.recognitionGeneration = 4
    initial.translationGeneration = 8
    let store = TestStore(initialState: initial) { CaptureFeature() }
    store.exhaustivity = .off
    let frame = store.state.overlayFrame
    await store.send(.sourceInteractionBegan)
    #expect(store.state.overlayLines.isEmpty)
    #expect(!store.state.isTranslating)
    let afterScroll = store.state
    await store.send(.liveCaptureResponse(generation: 4, frame: frame, result: .success(capture())))
    await store.send(.translationResponse(
      generation: 8,
      lineID: line().id,
      key: .init(source: "en", strategy: .lowLatency, target: "ko", text: "Hello"),
      translation: .init(text: "안녕하세요")
    ))
    expectNoDifference(store.state, afterScroll)
    await store.send(.dismissOverlay)
  }

  @Test
  func changedFrameHidesOldMasksBeforeNewOCRFinishes() async throws {
    var initial = state()
    var translated = line()
    translated.showTranslation("안녕하세요", language: Locale.Language(identifier: "ko"))
    initial.overlayLines = [translated]
    let clock = TestClock()
    let store = TestStore(initialState: initial) { CaptureFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.ocr = OCRClient(recognizeText: { _, _ in
        try await clock.sleep(for: .seconds(60))
        return OCRResult(lines: [])
      }, warmUp: { })
    }
    store.exhaustivity = .off
    await store.send(.liveFrameResponse(
      generation: 0,
      frame: store.state.overlayFrame,
      result: .success(try LiveFrame(image: image(gray: 0.8)))
    ))
    #expect(store.state.overlayLines.isEmpty)
    #expect(store.state.isCapturing)
    #expect(store.state.backdrop == nil)
    await store.send(.dismissOverlay)
    await store.finish()
  }

  @Test
  func failureClearsStaleContentAndAllowsIdenticalFrameRetry() async throws {
    var initial = state()
    initial.overlayLines = [line()]
    initial.lastFrameSignature = try LiveFrame(image: image(gray: 0.4)).signature
    let store = TestStore(initialState: initial) { CaptureFeature() }
    store.exhaustivity = .off
    await store.send(.liveFrameResponse(
      generation: 0,
      frame: store.state.overlayFrame,
      result: .failure(ScreenCaptureError.emptyRegion)
    ))
    #expect(store.state.overlayLines.isEmpty)
    #expect(store.state.lastFrameSignature == nil)
    #expect(store.state.lastError != nil)
    #expect(store.state.isLive)
  }

  @Test
  func requestGeometryUsesOriginalSnapshotSoSmallDriftCannotAccumulate() {
    let original = line().source
    let size = CGSize(width: 1000, height: 600)
    var drifted = original
    drifted.box.origin.x += 0.01
    #expect(drifted.canReuseTranslation(relativeTo: original, imageSize: size))
    drifted.box.origin.x += 0.01
    #expect(!drifted.canReuseTranslation(relativeTo: original, imageSize: size))
    var reflowed = original
    reflowed.box.size.width += 0.08
    #expect(!reflowed.canReuseTranslation(relativeTo: original, imageSize: size))
  }

  @Test
  func materialOCRMovementReplacesInFlightTranslationRequest() async {
    var initial = state()
    let original = line()
    initial.overlayLines = [original]
    initial.recognitionSettings = LiveFrame.Settings(initial.settings)
    initial.isTranslating = true
    initial.translationRequestContext = .init(
      strategy: .lowLatency,
      target: "ko",
      imageSize: CGSize(width: 1000, height: 600),
      sources: [original.id: original.source]
    )
    let requests = LockIsolated(0)
    let store = TestStore(initialState: initial) { CaptureFeature() } withDependencies: {
      $0.languageDetection = LanguageDetectionClient(detect: { _, _ in nil })
      $0.translation = TranslationClient(translateBatch: { items, _, _, _ in
        requests.withValue { $0 += 1 }
        return AsyncThrowingStream { continuation in
          for item in items { continuation.yield(.init(id: item.id, text: "안녕하세요")) }
          continuation.finish()
        }
      })
    }
    store.exhaustivity = .off
    var moved = capture()
    moved.result.lines[0].boundingBoxNormalized.origin.y += 0.2
    await store.send(.liveCaptureResponse(generation: 0, frame: initial.overlayFrame, result: .success(moved)))
    await store.receive(\.translationResponse)
    await store.receive(\.translationFinished)
    expectNoDifference(requests.value, 1)
    expectNoDifference(store.state.translationGeneration, 1)
    expectNoDifference(store.state.overlayLines[0].source.box, moved.result.lines[0].boundingBoxNormalized)
    expectNoDifference(store.state.overlayLines[0].translatedText, "안녕하세요")
  }

  @Test
  func cadenceAdaptsToChangesAndBacksOffAfterFailures() throws {
    let first = try LiveFrame(image: image(gray: 0.2)).signature
    let changed = try LiveFrame(image: image(gray: 0.7)).signature
    var cadence = LiveCaptureCadence()
    expectNoDifference(cadence.interval(after: first), .milliseconds(150))
    expectNoDifference(cadence.interval(after: first), .milliseconds(150))
    expectNoDifference(cadence.interval(after: first), .milliseconds(150))
    expectNoDifference(cadence.interval(after: first), .milliseconds(500))
    expectNoDifference(cadence.interval(after: changed), .milliseconds(150))
    expectNoDifference(cadence.interval(after: nil), .milliseconds(500))
    expectNoDifference(cadence.interval(after: nil), .seconds(1))
    expectNoDifference(cadence.interval(after: nil), .seconds(2))
    expectNoDifference(cadence.interval(after: nil), .seconds(2))
    expectNoDifference(cadence.interval(after: changed), .milliseconds(150))
  }

  @Test
  func legacyCaptureIntervalIsIgnoredAndNotWrittenBack() throws {
    let settings = try TOMLDecoder().decode(AppSettings.self, from: """
      [capture]
      interval = 99.0
      [languages.target]
      code = "ko"
      """)
    expectNoDifference(settings.languages.target, Language(code: "ko"))
    let encoded = String(decoding: try TOMLEncoder().encode(settings), as: UTF8.self)
    #expect(!encoded.contains("[capture]"))
    #expect(!encoded.contains("interval"))
  }

  // MARK: Private

  private func state() -> CaptureFeature.State {
    var state = CaptureFeature.State()
    state.overlayActive = true
    state.isLive = true
    state.$settings.withLock {
      $0.languages.source = Language(code: "en")
      $0.languages.target = Language(code: "ko")
    }
    return state
  }

  private func line() -> OverlayLine {
    OverlayLine(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      source: .init(recognized: capture().result.lines[0], language: Locale.Language(identifier: "en")),
      initialContent: .pending
    )
  }

  private func capture() -> CaptureFeature.LiveCapture {
    .init(backdrop: nil, imageSize: CGSize(width: 1000, height: 600), result: OCRResult(lines: [
      .init(boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.06), text: "Hello")
    ]))
  }

  private func image(gray: CGFloat) throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 32,
      height: 16,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    return try #require(context.makeImage())
  }
}
