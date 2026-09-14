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
  func identicalPixelsSkipOCRAndChangedPixelsCoalesceUntilDismissal() async throws {
    let first = try LiveFrame(image: image(gray: 0.2))
    let identical = try LiveFrame(image: image(gray: 0.2))
    let noisy = try LiveFrame(image: image(gray: 0.22))
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
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(noisy)))
    expectNoDifference(calls.value, 1)
    expectNoDifference(cancellations.value, 0)
    #expect(store.state.pendingRecognitionFrame == noisy)
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(identical)))
    #expect(store.state.pendingRecognitionFrame == nil)
    expectNoDifference(calls.value, 1)
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(noisy)))
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(changed)))
    expectNoDifference(calls.value, 1)
    expectNoDifference(cancellations.value, 0)
    expectNoDifference(store.state.recognitionGeneration, generation)
    #expect(store.state.pendingRecognitionFrame == changed)
    await store.send(.dismissOverlay)
    await store.finish()
    expectNoDifference(cancellations.value, 1)
  }

  @Test
  func discardedSettingsResponseRetiresOCRBeforeSettingsReturn() async throws {
    let first = try LiveFrame(image: image(gray: 0.2))
    let noisy = try LiveFrame(image: image(gray: 0.22))
    let continuations = LockIsolated<[AsyncThrowingStream<OCRResult, any Error>.Continuation]>([])
    let store = TestStore(initialState: state()) { CaptureFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.ocr = OCRClient(recognizeText: { _, _ in
        let stream = AsyncThrowingStream<OCRResult, any Error> { continuation in
          continuations.withValue { $0.append(continuation) }
        }
        for try await result in stream { return result }
        throw CancellationError()
      }, warmUp: { })
    }
    store.exhaustivity = .off
    let frame = store.state.overlayFrame
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(first)))
    for _ in 0..<100 where continuations.value.isEmpty { await Task.yield() }
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(noisy)))
    #expect(store.state.pendingRecognitionFrame == noisy)
    store.state.$settings.withLock { $0.languages.target = Language(code: "ja") }
    let oldOCR = try #require(continuations.value.first)
    oldOCR.yield(capture().result)
    oldOCR.finish()
    await store.receive(\.liveCaptureResponse)
    #expect(!store.state.recognitionInFlight)
    #expect(store.state.pendingRecognitionFrame == nil)
    #expect(store.state.lastFrameSignature == nil)
    #expect(store.state.overlayLines.isEmpty)

    store.state.$settings.withLock { $0.languages.target = Language(code: "ko") }
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(noisy)))
    for _ in 0..<100 where continuations.value.count < 2 { await Task.yield() }
    expectNoDifference(continuations.value.count, 2)
    #expect(store.state.recognitionInFlight)
    await store.send(.dismissOverlay)
    await store.finish()
  }

  @Test
  func continuousPixelChangesKeepTranslationAndPublishLatestOCR() async throws {
    let first = try LiveFrame(image: image(gray: 0.2))
    let second = try LiveFrame(image: image(gray: 0.9))
    let third = try LiveFrame(image: image(gray: 0.1))
    let newest = try LiveFrame(image: image(gray: 0.11))
    var initial = state()
    initial.lastFrameSignature = first.signature
    initial.recognitionFrame = first
    initial.recognitionSettings = LiveFrame.Settings(initial.settings)
    var translated = line()
    translated.showTranslation("안녕하세요", language: Locale.Language(identifier: "ko"))
    initial.overlayLines = [translated]
    initial.translationCache[.init(
      source: Locale.Language(identifier: "en").maximalIdentifier,
      strategy: .lowLatency,
      target: "ko",
      text: "Hello"
    )] = .init(text: "안녕하세요")
    let continuations = LockIsolated<[AsyncThrowingStream<OCRResult, any Error>.Continuation]>([])
    let recognizedFrames = LockIsolated<[LiveFrame.Signature]>([])
    let cancellations = LockIsolated(0)
    let store = TestStore(initialState: initial) { CaptureFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.uuid = .incrementing
      $0.ocr = OCRClient(recognizeText: { image, _ in
        let signature = try LiveFrame(image: image).signature
        recognizedFrames.withValue { $0.append(signature) }
        let stream = AsyncThrowingStream<OCRResult, any Error> { continuation in
          continuation.onTermination = { reason in
            if case .cancelled = reason { cancellations.withValue { $0 += 1 } }
          }
          continuations.withValue { $0.append(continuation) }
        }
        for try await result in stream { return result }
        throw CancellationError()
      }, warmUp: { })
      $0.languageDetection = LanguageDetectionClient(detect: { _, _ in nil })
      $0.translation = TranslationClient(translateBatch: { items, _, _, _ in
        AsyncThrowingStream { continuation in
          for item in items { continuation.yield(.init(id: item.id, text: "번역: " + item.text)) }
          continuation.finish()
        }
      })
    }
    store.exhaustivity = .off
    let frame = initial.overlayFrame
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(second)))
    for _ in 0..<100 where continuations.value.count < 1 { await Task.yield() }
    expectNoDifference(store.state.overlayLines, [translated])
    #expect(!store.state.isCapturing)
    #expect(store.state.recognitionInFlight)
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(third)))
    await store.send(.liveFrameResponse(generation: 0, frame: frame, result: .success(newest)))
    expectNoDifference(recognizedFrames.value, [second.signature])
    expectNoDifference(cancellations.value, 0)
    #expect(store.state.pendingRecognitionFrame == newest)

    let firstOCR = try #require(continuations.value.first)
    firstOCR.yield(capture().result)
    firstOCR.finish()
    await store.receive(\.liveCaptureResponse)
    for _ in 0..<100 where continuations.value.count < 2 { await Task.yield() }
    expectNoDifference(recognizedFrames.value, [second.signature, newest.signature])
    #expect(store.state.pendingRecognitionFrame == nil)

    expectNoDifference(store.state.overlayLines.map(\.translatedText), ["안녕하세요"])
    // Even a small source edit reaches OCR and replaces the previous text.
    // The earlier completed OCR is applied while a newer frame is pending.
    var changed = capture().result
    changed.lines[0].text = "Goodbye"
    let latestOCR = try #require(continuations.value.last)
    latestOCR.yield(changed)
    latestOCR.finish()
    await store.receive(\.liveCaptureResponse)
    await store.receive(\.translationResponse)
    await store.receive(\.translationFinished)
    expectNoDifference(store.state.overlayLines.map(\.source.text), ["Goodbye"])
    expectNoDifference(store.state.overlayLines.map(\.translatedText), ["번역: Goodbye"])
    expectNoDifference(cancellations.value, 0)
    #expect(!store.state.recognitionInFlight)
    await store.send(.dismissOverlay)
    #expect(store.state.recognitionFrame == nil)
    #expect(store.state.pendingRecognitionFrame == nil)
    await store.finish()
  }

  @Test
  func exactIdentityIncludesEveryPixelAndExcludesRowPadding() throws {
    func frame(padding: UInt8, changed: UInt8 = 10) throws -> LiveFrame {
      var pixels = [UInt8](repeating: padding, count: 32)
      for row in 0..<2 {
        for column in 0..<3 {
          let offset = row * 16 + column * 4
          pixels[offset] = 10
          pixels[offset + 1] = 10
          pixels[offset + 2] = 10
          pixels[offset + 3] = 255
        }
      }
      pixels[24] = changed
      let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
      let image = try #require(CGImage(
        width: 3,
        height: 2,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      ))
      return try LiveFrame(image: image)
    }
    let original = try frame(padding: 0)
    let changedPadding = try frame(padding: 255)
    let smallEdit = try frame(padding: 0, changed: 20)
    let smallBrightLabel = try frame(padding: 0, changed: 220)
    expectNoDifference(original.signature, changedPadding.signature)
    #expect(smallEdit.signature != original.signature)
    #expect(smallBrightLabel.signature != original.signature)
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
  func scrollInvalidatesBothLateOCRAndLateTranslations() async throws {
    var initial = state()
    initial.overlayLines = [line()]
    initial.isTranslating = true
    initial.recognitionGeneration = 4
    initial.translationGeneration = 8
    initial.recognitionFrame = try LiveFrame(image: image(gray: 0.2))
    initial.pendingRecognitionFrame = try LiveFrame(image: image(gray: 0.22))
    initial.recognitionInFlight = true
    let store = TestStore(initialState: initial) { CaptureFeature() }
    store.exhaustivity = .off
    let frame = store.state.overlayFrame
    await store.send(.sourceInteractionBegan)
    #expect(store.state.overlayLines.isEmpty)
    #expect(!store.state.isTranslating)
    #expect(!store.state.recognitionInFlight)
    #expect(store.state.recognitionFrame == nil)
    #expect(store.state.pendingRecognitionFrame == nil)
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
  func firstFrameWithoutRecognitionContextHidesOldMasks() async throws {
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
  func imageSizeChangeClearsTranslationAndCancelsOldRecognition() async throws {
    let first = try LiveFrame(image: image(gray: 0.2))
    var initial = state()
    initial.recognitionFrame = first
    initial.recognitionSettings = LiveFrame.Settings(initial.settings)
    initial.lastFrameSignature = first.signature
    initial.overlayLines = [line()]
    let calls = LockIsolated(0)
    let cancellations = LockIsolated(0)
    let store = TestStore(initialState: initial) { CaptureFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.ocr = OCRClient(recognizeText: { _, _ in
        calls.withValue { $0 += 1 }
        let stream = AsyncThrowingStream<OCRResult, any Error> { continuation in
          continuation.onTermination = { reason in
            if case .cancelled = reason { cancellations.withValue { $0 += 1 } }
          }
        }
        for try await result in stream { return result }
        throw CancellationError()
      }, warmUp: { })
    }
    store.exhaustivity = .off
    let frame = initial.overlayFrame
    await store.send(.liveFrameResponse(
      generation: 0,
      frame: frame,
      result: .success(try LiveFrame(image: image(gray: 0.9)))
    ))
    for _ in 0..<100 where calls.value < 1 { await Task.yield() }
    #expect(!store.state.overlayLines.isEmpty)
    let oldGeneration = store.state.recognitionGeneration
    await store.send(.liveFrameResponse(
      generation: 0,
      frame: frame,
      result: .success(try LiveFrame(image: image(gray: 0.9, width: 64)))
    ))
    for _ in 0..<100 where calls.value < 2 || cancellations.value < 1 { await Task.yield() }
    expectNoDifference(calls.value, 2)
    expectNoDifference(cancellations.value, 1)
    #expect(store.state.overlayLines.isEmpty)
    #expect(store.state.recognitionGeneration > oldGeneration)
    #expect(store.state.pendingRecognitionFrame == nil)
    let resizedState = store.state
    await store.send(.liveCaptureResponse(generation: oldGeneration, frame: frame, result: .success(capture())))
    expectNoDifference(store.state, resizedState)
    await store.send(.dismissOverlay)
    await store.finish()
  }

  @Test
  func emptyOCRRetiresTranslationAndRejectsItsLateResponse() async {
    var initial = state()
    initial.overlayLines = [line()]
    initial.isTranslating = true
    initial.translationGeneration = 8
    initial.recognitionSettings = LiveFrame.Settings(initial.settings)
    let store = TestStore(initialState: initial) { CaptureFeature() }
    store.exhaustivity = .off
    var empty = capture()
    empty.result.lines = []
    await store.send(.liveCaptureResponse(generation: 0, frame: initial.overlayFrame, result: .success(empty)))
    #expect(store.state.overlayLines.isEmpty)
    #expect(!store.state.isTranslating)
    #expect(store.state.translationRequestContext == nil)
    let cleared = store.state
    await store.send(.translationResponse(
      generation: 8,
      lineID: line().id,
      key: .init(source: "en", strategy: .lowLatency, target: "ko", text: "Hello"),
      translation: .init(text: "안녕하세요")
    ))
    expectNoDifference(store.state, cleared)
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

  private func image(gray: CGFloat, width: Int = 32) throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: 16,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 16))
    return try #require(context.makeImage())
  }
}
