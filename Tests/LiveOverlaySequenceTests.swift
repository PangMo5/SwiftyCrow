// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Live overlay visual freshness")
struct LiveOverlaySequenceTests {

  // MARK: Internal

  @Test(arguments: ["en", "ko", "ja", "zh-Hans", "ar", "de"])
  func repeatedOCRMeasurementDoesNotChangeDisplayedFont(_ language: String) {
    let original = source(language: language)
    var previous = original
    for tick in 0..<40 {
      var current = original
      current.box.origin.x += tick.isMultiple(of: 2) ? 0.001 : -0.001
      current.appearance.fontSizeScale = tick.isMultiple(of: 2) ? 0.045 : 0.065
      current.appearance.inkHeightScale += tick.isMultiple(of: 2) ? 0.001 : -0.001
      let stable = current.stabilized(relativeTo: previous, imageSize: CGSize(width: 800, height: 400))
      #expect(stable.appearance.fontSizeScale == 0.05)
      #expect(stable.box == current.box)
      previous = stable
    }
    var changedFont = original
    changedFont.appearance.inkHeightScale = 0.075
    changedFont.appearance.fontSizeScale = 0.09
    #expect(changedFont.stabilized(relativeTo: previous, imageSize: CGSize(width: 800, height: 400)).appearance
      .fontSizeScale == 0.09)
  }

  @Test
  func localWitnessIgnoresUnrelatedAnimationAndDetectsOneChangedSourcePixel() throws {
    let first = try frame(changedX: nil)
    let region = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4)
    let witness = try #require(first.witness(for: region))
    #expect(try frame(changedX: 90).matches(witness))
    #expect(try !frame(changedX: 25).matches(witness))
    #expect(try frame(changedX: nil).matches(witness))
  }

  @Test
  func witnessIncludesRestorationBleedOutsideTheOCRBox() throws {
    let image = try frame(changedX: nil)
    var text = source(language: "en")
    text.box = CGRect(x: 0.3, y: 0.1, width: 0.3, height: 0.4)
    text.replacementPatches = [.init(box: text.box)]
    let witness = try #require(image.witness(for: text))
    // x=25 is outside the original box (starts at x=30), but inside the
    // restoration bleed for this tall OCR line.
    #expect(try !frame(changedX: 25).matches(witness))
  }

  @Test(arguments: [OverlayLiveMode.inPlace, .window]) @MainActor
  func changedPixelsNeverPaintOldInPlaceRestorationWhileOCRIsPending(_ mode: OverlayLiveMode) async throws {
    let original = try frame(changedX: nil)
    let unrelated = try frame(changedX: 90)
    let changed = try frame(changedX: 25)
    let clock = TestClock()
    var state = withDependencies { $0.defaultFileStorage = .inMemory } operation: { CaptureFeature.State() }
    state.$settings.withLock { $0.overlay.liveMode = mode }
    state.isLive = true
    state.overlayActive = true
    state.imageSize = original.imageSize
    state.recognitionFrame = original
    state.lastFrameSignature = original.signature
    state.recognitionSettings = LiveFrame.Settings(state.settings)
    var line = OverlayLine(id: UUID(), source: source(language: "en"))
    line.showTranslation("설정", language: Locale.Language(identifier: "ko"))
    state.overlayLines = [line]
    let witness: LiveFrame.Witness = try #require(original.witness(for: line.source.box))
    state.visualSourceWitnesses[line.id] = witness
    let store = TestStore(initialState: state) { CaptureFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.ocr.recognizeText = { _, _ in
        try await clock.sleep(for: .seconds(60))
        return .init(lines: [])
      }
    }
    store.exhaustivity = .off
    let rect = state.overlayFrame
    await store.send(.liveFrameResponse(generation: 0, frame: rect, result: .success(unrelated)))
    #expect(store.state.overlayLines[0].shouldReplaceSourcePixels)
    await store.send(.liveFrameResponse(generation: 0, frame: rect, result: .success(changed)))
    #expect(store.state.overlayLines[0].translatedText == "설정")
    #expect(store.state.overlayLines[0].shouldReplaceSourcePixels == (mode == .window))
    #expect(store.state.recognitionInFlight)
    let generation = store.state.recognitionGeneration
    // Rapid A/B/A changes can restore the existing result without another translation.
    await store.send(.liveFrameResponse(generation: 0, frame: rect, result: .success(original)))
    #expect(store.state.overlayLines[0].shouldReplaceSourcePixels)
    #expect(store.state.recognitionGeneration == generation)
    await store.send(.dismissOverlay)
    #expect(store.state.visualSourceWitnesses.isEmpty)
    await store.finish()
  }

  // MARK: Private

  private func source(language: String) -> OverlayLine.Source {
    .init(
      recognized: .init(
        boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4),
        text: "Settings",
        horizontalInkScale: 0.04,
        appearance: .init(
          background: .white,
          foreground: .black,
          confidence: 1,
          inkHeightScale: 0.04,
          fontSizeScale: 0.05,
          fontWeight: .regular
        )
      ),
      language: Locale.Language(identifier: language)
    )
  }

  private func frame(changedX: Int?) throws -> LiveFrame {
    var bytes = [UInt8](repeating: 255, count: 100 * 60 * 4)
    if let changedX { bytes[(15 * 100 + changedX) * 4] = 0 }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(CGImage(
      width: 100,
      height: 60,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 400,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ))
    return try LiveFrame(image: image)
  }
}
